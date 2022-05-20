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
-- @file        build_cache.lua
--

-- imports
import("core.base.bytes")
import("core.base.hashset")
import("core.project.config")

-- is enabled?
function is_enabled()
    local build_cache = _g.build_cache
    if build_cache == nil then
        build_cache = config.get("ccache") or false
        _g.build_cache = build_cache
    end
    return build_cache or false
end

-- is supported?
function is_supported(sourcekind)
    local sourcekinds = _g.sourcekinds
    if sourcekinds == nil then
        sourcekinds = hashset.of("cc", "cxx", "mm", "mxx")
        _g.sourcekinds = sourcekinds
    end
    return sourcekinds:has(sourcekind)
end

-- get cache key
function cachekey(program, cppfile, cppflags, envs)
    local items = {program}
    for _, cppflag in ipairs(cppflags) do
        table.insert(items, cppflag)
    end
    table.sort(items)
    table.insert(items, hash.xxhash128(cppfile))
    if envs then
        local basename = path.basename(program)
        if basename == "cl" then
            for _, name in ipairs({"WindowsSDKVersion", "VCToolsVersion", "LIB"}) do
                local val = envs[name]
                if val then
                    table.insert(items, val)
                end
            end
        end
    end
    return hash.xxhash128(bytes(table.concat(items, "")))
end

-- get cache root directory
function rootdir()
    local cachedir = config.get("cachedir")
    return cachedir or path.join(config.buildir(), ".build_cache")
end

-- clean cached files
function clean()
    os.rm(rootdir())
end

-- get hit rate
function hitrate()
    local hit_count = (_g.hit_count or 0)
    local total_count = (_g.total_count or 0)
    if total_count > 0 then
        return math.floor(hit_count * 100 / total_count)
    end
    return 0
end

-- dump stats
function dump_stats()
    local hit_count = (_g.hit_count or 0)
    local total_count = (_g.total_count or 0)
    local newfiles_count = (_g.newfiles_count or 0)
    local preprocess_error_count = (_g.preprocess_error_count or 0)
    vprint("")
    vprint("build cache stats:")
    vprint("cache directory: %s", rootdir())
    vprint("cache hit rate: %d%%", hitrate())
    vprint("cache hit: %d", hit_count)
    vprint("cache miss: %d", total_count - hit_count)
    vprint("new cached files: %d", newfiles_count)
    vprint("preprocess failed: %d", preprocess_error_count)
    vprint("")
end

-- get object file
function get(cachekey)
    _g.total_count = (_g.total_count or 0) + 1
    local objectfile_cached = path.join(rootdir(), cachekey:sub(1, 2):lower(), cachekey)
    if os.isfile(objectfile_cached) then
        _g.hit_count = (_g.hit_count or 0) + 1
        return objectfile_cached
    end
end

-- put object file
function put(cachekey, objectfile)
    local objectfile_cached = path.join(rootdir(), cachekey:sub(1, 2):lower(), cachekey)
    os.cp(objectfile, objectfile_cached)
    _g.newfiles_count = (_g.newfiles_count or 0) + 1
end

-- build with cache
function build(program, argv, opt)

    -- do preprocess
    opt = opt or {}
    local preprocess = assert(opt.preprocess, "preprocessor not found!")
    local compile = assert(opt.compile, "compiler not found!")
    local cppinfo = preprocess(program, argv, opt)
    if cppinfo then
        local cachekey = cachekey(program, cppinfo.cppfile, cppinfo.cppflags, opt.envs)
        local objectfile_cached = get(cachekey)
        if objectfile_cached then
            os.cp(objectfile_cached, cppinfo.objectfile)
        else
            -- do compile
            compile(program, cppinfo, opt)
            if cachekey then
                put(cachekey, cppinfo.objectfile)
            end
        end
        os.rm(cppinfo.cppfile)
    else
        _g.preprocess_error_count = (_g.preprocess_error_count or 0) + 1
    end
    return cppinfo
end
