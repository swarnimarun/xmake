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
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        clang.lua
--

-- imports
import("core.tool.compiler")
import("core.project.project")
import("core.project.depend")
import("core.project.config")
import("utils.progress")
import("private.action.build.object", {alias = "objectbuilder"})
import("common")

-- load module support for the current target
function load(target)
    local cachedir = common.modules_cachedir(target)
    local stlcachedir = common.stlmodules_cachedir(target)

    -- get module and module cache flags
    local modulesflag = get_modulesflag(target)
    local implicitmodulesflag = get_implicitmodulesflag(target)
    local implicitmodulemapsflag = get_implicitmodulemapsflag(target)
    local prebuiltmodulepathflag = get_prebuiltmodulepathflag(target)

    -- add module flags
    target:add("cxxflags", modulesflag)

    -- add the module cache directory
    target:add("cxxflags", implicitmodulesflag, {force = true})
    target:add("cxxflags", implicitmodulemapsflag, {force = true})
    target:add("cxxflags", prebuiltmodulepathflag .. cachedir, prebuiltmodulepathflag .. stlcachedir, {force = true})

    -- add module cachedirs of all dependent targets with modules
    -- this target maybe does not contain module files, @see https://github.com/xmake-io/xmake/issues/1858
    for _, dep in ipairs(target:orderdeps()) do
        cachedir = common.modules_cachedir(dep)
        target:add("cxxflags", prebuiltmodulepathflag .. cachedir, {force = true})
    end
end

-- get includedirs for stl headers
--
-- $ echo '#include <vector>' | clang -x c++ -E - | grep '/vector"'
-- # 1 "/usr/include/c++/11/vector" 1 3
-- # 58 "/usr/include/c++/11/vector" 3
-- # 59 "/usr/include/c++/11/vector" 3
--
function _get_toolchain_includedirs_for_stlheaders(includedirs, clang)
    local tmpfile = os.tmpfile() .. ".cc"
    io.writefile(tmpfile, "#include <vector>")
    local result = try {function () return os.iorunv(clang, {"-E", "-x", "c++", tmpfile}) end}
    if result then
        for _, line in ipairs(result:split("\n", {plain = true})) do
            line = line:trim()
            if line:startswith("#") and line:find("/vector\"", 1, true) then
                local includedir = line:match("\"(.+)/vector\"")
                if includedir and os.isdir(includedir) then
                    table.insert(includedirs, path.normalize(includedir))
                    break
                end
            end
        end
    end
    os.tryrm(tmpfile)
end

-- provide toolchain include directories for stl headerunit when p1689 is not supported
function toolchain_includedirs(target)
    local includedirs = _g.includedirs
    if includedirs == nil then
        includedirs = {}
        local clang, toolname = target:tool("cc")
        assert(toolname == "clang")
        _get_toolchain_includedirs_for_stlheaders(includedirs, clang)
        local _, result = try {function () return os.iorunv(clang, {"-E", "-Wp,-v", "-xc", os.nuldev()}) end}
        if result then
            for _, line in ipairs(result:split("\n", {plain = true})) do
                line = line:trim()
                if os.isdir(line) then
                    table.insert(includedirs, path.normalize(line))
                elseif line:startswith("End") then
                    break
                end
            end
        end
        _g.includedirs = includedirs
    end
    return includedirs
end

-- generate dependency files
function generate_dependencies(target, sourcebatch, opt)
    local cachedir = common.modules_cachedir(target)
    for _, sourcefile in ipairs(sourcebatch.sourcefiles) do
        local dependfile = target:dependfile(sourcefile)
        depend.on_changed(function()
            if opt.progress then
                progress.show(opt.progress, "${color.build.object}generating.cxx.module.deps %s", sourcefile)
            end

            local outdir = path.translate(path.join(cachedir, path.directory(path.relative(sourcefile, projectdir))))
            if not os.isdir(outdir) then
                os.mkdir(outdir)
            end

            -- no support of p1689 atm
            local jsonfile = path.translate(path.join(outdir, path.filename(sourcefile) .. ".json"))
            common.fallback_generate_dependencies(target, jsonfile, sourcefile)

            local dependinfo = io.readfile(jsonfile)
            return { moduleinfo = dependinfo }
        end, {dependfile = dependfile, files = {sourcefile}})
    end
end

-- generate target stl header units
function generate_stl_headerunits(target, batchcmds, headerunits, opt)
    local compinst = target:compiler("cxx")

    -- get cachedirs
    local stlcachedir = common.stlmodules_cachedir(target)

    -- get headerunits flags
    local modulecachepathflag = get_modulecachepathflag(target)
    local modulefileflag = get_modulefileflag(target)

    -- build headerunits
    local projectdir = os.projectdir()
    local flags = {}
    local depmtime = 0
    for i, headerunit in ipairs(headerunits) do
        local bmifile = path.join(stlcachedir, headerunit.name .. get_bmi_extension())
        if not os.isfile(bmifile) then
            local args = {modulecachepathflag .. stlcachedir, "-c", "-o", bmifile, "-x", "c++-system-header", headerunit.path}
            batchcmds:show_progress(opt.progress, "${color.build.object}generating.cxx.headerunit.bmi %s", headerunit.name)
            batchcmds:vrunv(compinst:program(), table.join(compinst:compflags({target = target}), args))
        end

        table.insert(flags, modulefileflag .. bmifile)
        depmtime = math.max(depmtime, os.mtime(bmifile))
    end
    batchcmds:set_depmtime(depmtime)
    return flags
end

-- generate target user header units
function generate_user_headerunits(target, batchcmds, headerunits, opt)
    local compinst = target:compiler("cxx")
    assert(has_headerunitsupport(target), "compiler(clang): does not support c++ header units!")

    -- get cachedirs
    local cachedir = common.modules_cachedir(target)

    -- get headerunits flags
    local modulecachepathflag = get_modulecachepathflag(target)
    local emitmoduleflag = get_emitmoduleflag(target)
    local modulefileflag = get_modulefileflag(target)

    -- build headerunits
    local objectfiles = {}
    local flags = {}
    local projectdir = os.projectdir()
    local depmtime = 0
    for _, headerunit in ipairs(headerunits) do
        local file = path.relative(headerunit.path, target:scriptdir())
        local objectfile = target:objectfile(file)

        local outdir
        if headerunit.type == ":quote" then
            outdir = path.join(cachedir, path.directory(path.relative(headerunit.path, projectdir)))
        else
            outdir = path.join(cachedir, path.directory(headerunit.path))
        end
        batchcmds:mkdir(outdir)

        local bmifilename = path.basename(objectfile) .. get_bmi_extension()
        local bmifile = (outdir and path.join(outdir, bmifilename) or bmifilename)
        batchcmds:mkdir(path.directory(objectfile))

        local args = { modulecachepathflag .. cachedir, emitmoduleflag, "-c", "-o", bmifile}
        if headerunit.type == ":quote" then
            table.join2(args, {"-I", path.directory(headerunit.path), "-x", "c++-user-header", headerunit.path})
        elseif headerunit.type == ":angle" then
            table.join2(args, {"-x", "c++-system-header", headerunit.name})
        end

        batchcmds:show_progress(opt.progress, "${color.build.object}generating.cxx.headerunit.bmi %s", headerunit.name)
        batchcmds:vrunv(compinst:program(), table.join(compinst:compflags({target = target}), args))

        batchcmds:add_depfiles(headerunit.path)

        table.insert(flags, modulefileflag .. bmifile)
        depmtime = math.max(depmtime, os.mtime(bmifile))
    end
    batchcmds:set_depmtime(depmtime)
    return flags
end

-- build module files
function build_modules(target, batchcmds, objectfiles, modules, opt)
    local compinst = target:compiler("cxx")

    -- get cachedirs
    local cachedir = common.modules_cachedir(target)

    -- get modules flags
    local modulecachepathflag = get_modulecachepathflag(target)
    local emitmoduleinterfaceflag = get_emitmoduleinterfaceflag(target)
    local modulefileflag = get_modulefileflag(target)

    -- append deps modules
    for _, dep in ipairs(target:orderdeps()) do
        local flags = dep:data("cxx.modules.flags")
        if flags then
            target:add("cxxflags", flags, {force = true, expand = false})
        end
    end

    -- build modules
    local common_args = {modulecachepathflag .. cachedir}
    local depmtime = 0
    for _, objectfile in ipairs(objectfiles) do
        local m = modules[objectfile]
        if m and m.provides then
            -- assume there that provides is only one, until we encounter the case
            local length = 0
            local name, provide
            for k, v in pairs(m.provides) do
                length = length + 1
                name = k
                provide = v
                if length > 1 then
                    raise("multiple provides are not supported now!")
                end
            end

            local bmifile = provide.bmi
            local args = { emitmoduleinterfaceflag, "-c", "-x", "c++-module", "--precompile", provide.sourcefile, "-o", bmifile }
            batchcmds:show_progress(opt.progress, "${color.build.object}generating.cxx.module.bmi %s", name)
            batchcmds:mkdir(path.directory(objectfile))
            batchcmds:vrunv(compinst:program(), table.join(compinst:compflags({target = target}), common_args, args))
            batchcmds:vrunv(compinst:program(), table.join(compinst:compflags({target = target}), common_args, {bmifile}, {"-c", "-o", objectfile}))
            batchcmds:add_depfiles(provide.sourcefile)

            local bmiflags = modulefileflag .. bmifile
            target:add("cxxflags", bmiflags, {public = true, force = true})
            target:add("objectfiles", objectfile)
            target:data_add("cxx.modules.flags", bmiflags)
            depmtime = math.max(depmtime, os.mtime(bmifile))
        end
    end
    batchcmds:set_depmtime(depmtime)
end

function get_bmi_extension()
    return ".pcm"
end

function get_modulesflag(target)
    local modulesflag = _g.modulesflag
    if modulesflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fmodules", "cxxflags", {flagskey = "clang_modules"}) then
            modulesflag = "-fmodules"
        end
        if not modulesflag then
            if compinst:has_flags("-fmodules-ts", "cxxflags", {flagskey = "clang_modules_ts"}) then
                modulesflag = "-fmodules-ts"
            end
        end
        assert(modulesflag, "compiler(clang): does not support c++ module!")
        _g.modulesflag = modulesflag or false
    end
    return modulesflag or nil
end

function get_implicitmodulesflag(target)
    local implicitmodulesflag = _g.implicitmodulesflag
    if implicitmodulesflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fimplicit-modules", "cxxflags", {flagskey = "clang_implicit_modules"}) then
            implicitmodulesflag = "-fimplicit-modules"
        end
        assert(implicitmodulesflag, "compiler(clang): does not support c++ module!")
        _g.implicitmodulesflag = implicitmodulesflag or false
    end
    return implicitmodulesflag or nil
end

function get_implicitmodulemapsflag(target)
    local implicitmodulemapsflag = _g.implicitmodulemapsflag
    if implicitmodulemapsflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fimplicit-module-maps", "cxxflags", {flagskey = "clang_implicit_module_maps"}) then
            implicitmodulemapsflag = "-fimplicit-module-maps"
        end
        assert(implicitmodulemapsflag, "compiler(clang): does not support c++ module!")
        _g.implicitmodulemapsflag = implicitmodulemapsflag or false
    end
    return implicitmodulemapsflag or nil
end

function get_prebuiltmodulepathflag(target)
    local prebuiltmodulepathflag = _g.prebuiltmodulepathflag
    if prebuiltmodulepathflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fprebuilt-module-path=" .. os.tmpdir(), "cxxflags", {flagskey = "clang_prebuild_module_path"}) then
            prebuiltmodulepathflag = "-fprebuilt-module-path="
        end
        assert(prebuiltmodulepathflag, "compiler(clang): does not support c++ module!")
        _g.prebuiltmodulepathflag = prebuiltmodulepathflag or false
    end
    return prebuiltmodulepathflag or nil
end

function get_modulecachepathflag(target)
    local modulecachepathflag = _g.modulecachepathflag
    if modulecachepathflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fmodules-cache-path=" .. os.tmpdir(), "cxxflags", {flagskey = "clang_modules_cache_path"}) then
            modulecachepathflag = "-fmodules-cache-path="
        end
        assert(modulecachepathflag, "compiler(clang): does not support c++ module!")
        _g.modulecachepathflag = modulecachepathflag or false
    end
    return modulecachepathflag or nil
end

function get_emitmoduleflag(target)
    local emitmoduleflag = _g.emitmoduleflag
    if emitmoduleflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-emit-module", "cxxflags", {flagskey = "clang_emit_module"}) then
            emitmoduleflag = "-emit-module"
        end
        assert(emitmoduleflag, "compiler(clang): does not support c++ module!")
        _g.emitmoduleflag = emitmoduleflag or false
    end
    return emitmoduleflag or nil
end

function get_modulefileflag(target)
    local modulefileflag = _g.modulefileflag
    if modulefileflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-fmodule-file=" .. os.tmpfile() .. get_bmi_extension(), "cxxflags", {flagskey = "clang_module_file"}) then
            modulefileflag = "-fmodule-file="
        end
        assert(modulefileflag, "compiler(clang): does not support c++ module!")
        _g.modulefileflag = modulefileflag or false
    end
    return modulefileflag or nil
end

function get_emitmoduleinterfaceflag(target)
    local emitmoduleinterfaceflag = _g.emitmoduleinterfaceflag
    if emitmoduleinterfaceflag == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-emit-module-interface", "cxxflags", {flagskey = "clang_emit_module_interface"}) then
            emitmoduleinterfaceflag = "-emit-module-interface"
        end
        assert(emitmoduleinterfaceflag, "compiler(clang): does not support c++ module!")
        _g.emitmoduleinterfaceflag = emitmoduleinterfaceflag or false
    end
    return emitmoduleinterfaceflag or nil
end

function has_headerunitsupport(target)
    local support_headerunits = _g.support_headerunits
    if support_headerunits == nil then
        local compinst = target:compiler("cxx")
        if compinst:has_flags("-x c++-user-header", "cxxflags", {flagskey = "clang_user_header_unit_support", tryrun = true}) and
           compinst:has_flags("-x c++-system-header", "cxxflags", {flagskey = "clang_system_header_unit_support", tryrun = true}) then
            support_headerunits = true
        end
        _g.support_headerunits = support_headerunits or false
    end
    return support_headerunits or nil
end
