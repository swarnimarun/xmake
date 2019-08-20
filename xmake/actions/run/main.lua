--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- 
-- Copyright (C) 2015 - 2019, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        main.lua
--

-- imports
import("core.base.option")
import("core.base.task")
import("core.base.hashset")
import("core.project.config")
import("core.base.global")
import("core.project.project")
import("core.platform.platform")
import("core.platform.environment")
import("devel.debugger")

-- add search directories for all dependent shared libraries on windows
function _make_runpath(target)

    if not (is_plat("windows") or (is_plat("mingw") and is_host("windows"))) then
        return {}
    end

    local searchdirs = hashset.new()
    local pathenv = {}

    local function insert(dir)
        if not path.is_absolute(dir) then
            dir = path.absolute(dir, os.projectdir())
        end
        if searchdirs:insert(dir) then
            table.insert(pathenv, dir)
        end
    end

    for _, linkdir in ipairs(target:get("linkdirs")) do
        insert(linkdir)
    end
    for _, opt in ipairs(target:orderopts()) do
        for _, linkdir in ipairs(opt:get("linkdirs")) do
            insert(linkdir)
        end
    end
    for _, dep in ipairs(target:orderdeps()) do
        if dep:targetkind() == "shared" then
            insert(dep:targetdir())
        end
    end
    return pathenv
end

-- run target
function _do_run_target(target)
    if target:targetkind() ~= "binary" then
        return
    end

    -- get the run directory of target
    local rundir = target:rundir()

    -- get the absolute target file path
    local targetfile = path.absolute(target:targetfile())

    -- enter the run directory
    local oldir = os.cd(rundir)

    -- add run environments
    local runenvs = target:get("runenvs")
    if runenvs then
        for name, values in pairs(runenvs) do
            os.addenv(name, unpack(table.wrap(values)))
        end
    end
    local runenv = target:get("runenv")
    if runenv then
        for name, value in pairs(runenv) do
            os.setenv(name, unpack(table.wrap(value)))
        end
    end

    os.addenv("PATH", table.unpack(_make_runpath(target)))

    -- debugging?
    if option.get("debug") then
        debugger.run(targetfile, option.get("arguments"))
    else
        os.execv(targetfile, option.get("arguments"))
    end

    -- restore the previous directory
    os.cd(oldir)
end

-- run target 
function _on_run_target(target)

    -- has been disabled?
    if target:get("enabled") == false then
        return
    end

    -- build target with rules
    local done = false
    for _, r in ipairs(target:orderules()) do
        local on_run = r:script("run")
        if on_run then
            on_run(target, {origin = _do_run_target})
            done = true
        end
    end
    if done then return end

    -- do run
    _do_run_target(target)
end

-- run the given target 
function _run(target)

    -- enter the environments of the target packages
    local oldenvs = {}
    for name, values in pairs(target:pkgenvs()) do
        oldenvs[name] = os.getenv(name)
        os.addenv(name, unpack(values))
    end

    -- the target scripts
    local scripts =
    {
        target:script("run_before")
    ,   function (target)

            -- has been disabled?
            if target:get("enabled") == false then
                return 
            end

            -- run rules
            for _, r in ipairs(target:orderules()) do
                local before_run = r:script("run_before")
                if before_run then
                    before_run(target)
                end
            end
        end
    ,   target:script("run", _on_run_target)
    ,   function (target)

            -- has been disabled?
            if target:get("enabled") == false then
                return 
            end

            -- run rules
            for _, r in ipairs(target:orderules()) do
                local after_run = r:script("run_after")
                if after_run then
                    after_run(target)
                end
            end
        end
    ,   target:script("run_after")
    }

    -- run the target scripts
    for i = 1, 5 do
        local script = scripts[i]
        if script ~= nil then
            script(target, {origin = (i == 3 and _do_run_target or nil)})
        end
    end

    -- leave the environments of the target packages
    for name, values in pairs(oldenvs) do
        os.setenv(name, values)
    end
end

-- run the all dependent targets
function _run_deps(target)
    for _, dep in ipairs(target:orderdeps()) do
        _run(dep)
    end
end

-- check targets
function _check_targets(targetname)

    -- get targets
    local targets = {}
    if targetname and not targetname:startswith("__") then
        table.insert(targets, project.target(targetname))
    else
        -- install default or all targets
        for _, target in pairs(project.targets()) do
            local default = target:get("default")
            if (default == nil or default == true or option.get("all")) and target:targetkind() == "binary" then
                table.insert(targets, target)
            end
        end
    end

    -- filter and check targets with builtin-run script
    local targetnames = {}
    for _, target in ipairs(targets) do
        if not target:isphony() and target:get("enabled") ~= false and not target:script("run") then
            local targetfile = target:targetfile()
            if targetfile and not os.isfile(targetfile) then
                table.insert(targetnames, target:name())
            end
        end
    end

    -- there are targets that have not yet been built?
    if #targetnames > 0 then
        raise("please run `$xmake [target]` to build the following targets first:\n  -> " .. table.concat(targetnames, '\n  -> '))
    end
end

-- main
function main()

    -- get the target name
    local targetname = option.get("target")

    -- config it first
    task.run("config", {target = targetname, require = "n"})

    -- check targets first
    _check_targets(targetname)

    -- enter project directory
    local oldir = os.cd(project.directory())

    -- enter the running environment
    environment.enter("run")

    -- run the given target?
    if targetname then
        _run_deps(project.target(targetname))
        _run(project.target(targetname))
    else
        -- run default or all binary targets
        for _, target in pairs(project.targets()) do
            local default = target:get("default")
            if (default == nil or default == true or option.get("all")) and target:targetkind() == "binary" then
                _run_deps(target)
                _run(target)
            end
        end
    end

    -- leave the running environment
    environment.leave("run")

    -- leave project directory
    os.cd(oldir)
end

