os = require 'os'
path = require 'path'
fs = require 'fs'
util = require 'echo-util'
{ spawn } = require 'child_process'
debug = require 'debug'
{ Set } = require 'set'
{ Map } = require 'map'
{ LLVM_SUFFIX } = require 'host-config'
        
# if we're running under coffee/node, argv will be ["coffee", ".../ejs", ...]
# if we're running the compiled ejs.exe, argv will be [".../ejs.js.exe", ...]
slice_count = if __ejs? then 1 else 2
argv = process.argv.slice slice_count

files = []
temp_files = []

host_arch = os.arch()
host_arch = "x86_64" if host_arch is "x64" # why didn't we just standardize on 'amd64'?  sigh
host_arch = "x86"    if host_arch is "ia32"

host_platform = os.platform()

options =
        # our defaults:
        debug_level: 0
        debug_passes: new Set
        warn_on_undeclared: false
        frozen_global: false
        record_types: false
        output_filename: null
        show_help: false
        leave_temp_files: false
        target_arch: host_arch
        target_platform: host_platform
        native_module_dirs: []
        extra_clang_args: ""
        ios_sdk: "7.1"
        ios_min: "7.0"
        target_pointer_size: 64
        import_variables: []
        srcdir: false

add_native_module_dir = (dir) ->
        options.native_module_dirs.push(dir)

arch_info = {
        "x86_64": { pointer_size: 64, little_endian: true, llc_arch: "x86-64",  clang_arch: "x86_64" }
        x86:      { pointer_size: 32, little_endian: true, llc_arch: "x86",     clang_arch: "i386" }
        arm:      { pointer_size: 32, little_endian: true, llc_arch: "arm",     clang_arch: "armv7" }
        aarch64:  { pointer_size: 64, little_endian: true, llc_arch: "aarch64", clang_arch: "aarch64" }
}

set_target_arch = (arch) ->
        if options.target?
                throw new Error "--arch and --target cannot be specified at the same time"

        # we accept some arch aliases

        arch = "x86_64" if arch is "amd64"
        arch = "x86"    if arch is "i386"

        if not arch in arch_info
                throw new Error "invalid arch `#{arch}'."
                
        options.target_arch         = arch
        options.target_pointer_size = arch_info[arch].pointer_size

set_target = (platform, arch) ->
        options.target_platform     = platform
        options.target_arch         = arch
        options.target_pointer_size = arch_info[arch].pointer_size

set_target_alias = (alias) ->
        target_aliases = {
                linux_amd64: { platform: "linux",  arch: "x86_64" },
                osx:         { platform: "darwin", arch: "x86_64" },
                sim:         { platform: "darwin", arch: "x86" },
                dev:         { platform: "darwin", arch: "arm" },
        }
        if not alias in target_aliases
                throw new Error "invalid target alias `#{alias}'."

        options.target = alias
        set_target target_aliases[alias].platform, target_aliases[alias].arch

set_extra_clang_args = (arginfo) ->
        options.extra_clang_args = arginfo

increase_debug_level = ->
        options.debug_level += 1

add_debug_after_pass = (passname) ->
        options.debug_passes.add passname

add_import_variable = (arg) ->
        equal_idx = arg.indexOf('=')
        if equal_idx == -1
                throw new Error "-I flag requires <name>=<value>"

        options.import_variables.push({ variable: arg.substring(0, equal_idx), value: arg.substring(equal_idx+1) })
        
args =
        "-q":
                flag:    "quiet"
                help:    "don't output anything during compilation except errors."
        "-I":
                handler: add_import_variable
                handlerArgc: 1
                help:    "add a name=value mapping used to resolve module references."
        "-d":
                handler: increase_debug_level
                handlerArgc: 0
                help:    "debug output.  more instances of this flag increase the amount of spew."
        "--debug-after":
                handler: add_debug_after_pass
                handlerArgc: 1
                help:    "dump the IR tree after the named pass"
        "-o":
                option:  "output_filename"
                help:    "name of the output file."
        "--leave-temp":
                flag:    "leave_temp_files"
                help:    "leave temporary files in $TMPDIR from compilation"
        "--moduledir":
                handler: add_native_module_dir
                handlerArgc: 1
                help:    "--moduledir path-to-search-for-modules"
        "--help":
                flag:    "show_help",
                help:    "output this help info."
        "--extra-clang-args":
                handler: set_extra_clang_args
                handlerArgc: 1
                help:    "extra arguments to pass to the clang command (used to compile the .s to .o)"
        "--record-types":
                flag:    "record_types"
                help:    "generates an executable which records types in a format later used for optimizations."
        "--frozen-global":
                flag:    "frozen_global"
                help:    "compiler acts as if the global object is frozen after initialization, allowing for faster access."
        "--warn-on-undeclared":
                flag:    "warn_on_undeclared"
                help:    "accesses to undeclared identifiers result in warnings (and global accesses).  By default they're an error."
        
        "--arch":
                handler: set_target_arch
                handlerArgc: 1
                help:    "--arch x86_64|x86|arm|aarch64"

        "--target":
                handler: set_target_alias
                handlerArgc: 1
                help:    "--target linux_amd64|osx|sim|dev"
                
        "--ios-sdk":
                option:  "ios_sdk"
                help:    "the version of the ios sdk to use.  useful if more than one is installed.  Default is 7.0."
        "--ios-min":
                option:  "ios_min"
                help:    "the minimum version of ios to support.  Default is 7.0."

        "--srcdir":
                flag:    "srcdir"
                help:    "internal flag.  if set, will look for libecho/libpcre/etc from source directory locations."

output_usage = ->
        console.warn 'Usage:';
        console.warn '   ejs [options] file1.js file2.js file.js ...'
        
output_options = ->
        console.warn 'Options:'
        for a of args
                console.warn "   #{a}:  #{args[a].help}"

# default to the host platform/arch
set_target host_platform, host_arch

if argv.length > 0
        skipNext = 0
        for ai in [0..argv.length-1]
                if skipNext > 0
                        skipNext -= 1
                else
                        if args[argv[ai]]?
                                o = args[argv[ai]]
                                if o.flag?
                                        options[o.flag] = true
                                else if o.option?
                                        options[o.option] = argv[++ai]
                                        skipNext = 1
                                else if o.handler?
                                        handler_args = []
                                        handler_args.push argv[++ai] for i in [0...o.handlerArgc]
                                        o.handler.apply null, handler_args
                                        skipNext = o.handlerArgc
                        else
                                # end of options signals the rest of the array is files
                                file_args = argv.slice ai
                                break

if options.show_help
        output_usage()
        console.warn ''
        output_options()
        process.exit 0
        
if not file_args? or file_args.length is 0
        output_usage()
        process.exit 0

if not options.quiet
        console.log "running on #{host_platform}-#{host_arch}"
        console.log "generating code for #{options.target_platform}-#{options.target_arch}"

debug.setLevel options.debug_level

files_remaining = 0

o_filenames = []

compiled_modules = []

esprima = require 'esprima'
compiler = require 'compiler'

sim_base="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform"
dev_base="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform"

sim_bin="#{sim_base}/Developer/usr/bin"
dev_bin="#{dev_base}/Developer/usr/bin"

target_llc_args = (platform, arch) ->
        args = ["-march=#{arch_info[options.target_arch].llc_arch}", "-disable-fp-elim" ]
        if arch is "arm"
                args = args.concat ["-mtriple=thumbv7-apple-ios", "-mattr=+v6", "-relocation-model=pic", "-soft-float" ]
        if arch is "aarch64"
                args = args.concat ["-mtriple=thumbv7s-apple-ios", "-mattr=+fp-armv8", "-relocation-model=pic" ]
        args

target_linker = "clang++"
        
target_link_args = (platform, arch) ->
        args = [ "-arch", arch_info[options.target_arch].clang_arch ]

        if platform is "linux"
                # on ubuntu 14.04, at least, clang spits out a warning about this flag being unused (presumably because there's no other arch)
                return [] if arch is "x86_64"
                return args

        if platform is "darwin"
                return args if arch is "x86_64"
                if arch is "x86"                
                        return args.concat [ "-isysroot", "#{sim_base}/Developer/SDKs/iPhoneSimulator#{options.ios_sdk}.sdk", "-miphoneos-version-min=#{options.ios_min}" ]
                return args.concat [ "-isysroot", "#{dev_base}/Developer/SDKs/iPhoneOS#{options.ios_sdk}.sdk", "-miphoneos-version-min=#{options.ios_min}" ]
        []
        

target_libraries = (platform, arch) ->
        return [ "-lpthread", "-luv" ] if platform is "linux"

        if platform is "darwin"
                rv = [ "-framework", "Foundation" ]

                # for osx we only need Foundation and AppKit
                return rv.concat [ "-framework" , "AppKit" ] if arch is "x86_64"

                # for any other darwin we're dealing with ios, so...
                return rv.concat [ "-framework", "UIKit", "-framework", "GLKit", "-framework", "OpenGLES", "-framework", "CoreGraphics" ]
        []


target_libecho = (platform, arch) ->
        return "../../runtime/libecho.a"    if platform is "linux"
        if platform is "darwin"
                return "../../runtime/libecho.a" if arch is "x86_64"

                return "../../runtime/libecho.a.ios"

        throw new Error("shouldn't get here")

        
target_extra_libs = (platform, arch) ->
        return "../../external-deps/pcre-linux/.libs/libpcre16.a" if platform is "linux"

        if platform is "darwin"
                return "../../external-deps/pcre-osx/.libs/libpcre16.a" if arch is "x86_64"
                return "../../external-deps/pcre-iossim/.libs/libpcre16.a" if arch is "x86"
                return "../../external-deps/pcre-iosdev/.libs/libpcre16.a" if arch is "arm"
                return "../../external-deps/pcre-iosdevaarch64/.libs/libpcre16.a" if arch is "aarch64"

target_path_prepend = (platform, arch) ->
        if platform is "darwin"
                return "#{sim_bin}" if arch is "x86"
                return "#{dev_bin}" if arch is "arm" or arch is "aarch64"
        ""                

llvm_commands = {}
llvm_commands[x]="#{x}#{process.env.LLVM_SUFFIX || LLVM_SUFFIX}" for x in ["opt", "llc", "llvm-as"]

compileFile = (filename, parse_tree, modules, compileCallback) ->
        base_filename = util.genFreshFileName path.basename filename

        if not options.quiet
                suffix = if options.debug_level > 0 then " -> #{base_filename}" else ''
                console.warn "#{util.bold()}COMPILE#{util.reset()} #{filename}#{suffix}"

        try
                compiled_module = compiler.compile parse_tree, base_filename, filename, modules, options
        catch e
                console.warn "#{e}"
                process.exit(-1) if options.debug_level == 0
                throw e

        base_output_name = "#{os.tmpdir()}/#{base_filename}-#{options.target_platform}-#{options.target_arch}"
        ll_filename      = "#{base_output_name}.ll"
        bc_filename      = "#{base_output_name}.bc"
        ll_opt_filename  = "#{base_output_name}.ll.opt"
        o_filename       = "#{base_output_name}.o"

        temp_files.push ll_filename, bc_filename, ll_opt_filename, o_filename
        
        llvm_as_args = ["-o=#{bc_filename}", ll_filename]
        opt_args     = ["-O2", "-strip-dead-prototypes", "-S", "-o=#{ll_opt_filename}", bc_filename]
        llc_args     = target_llc_args(options.target_platform,options.target_arch).concat ["-filetype=obj", "-o=#{o_filename}", ll_opt_filename]

        debug.log 1, "writing #{ll_filename}"
        compiled_module.writeToFile ll_filename
        debug.log 1, "done writing #{ll_filename}"

        compiled_modules.push filename: (if options.basename then path.basename(filename) else filename), module_toplevel: compiled_module.toplevel_name

        debug.log 1, "executing `#{llvm_commands['llvm-as']} #{llvm_as_args.join ' '}'"
        llvm_as = spawn llvm_commands["llvm-as"], llvm_as_args
        llvm_as.stderr.on "data", (data) -> console.warn "#{data}"
        llvm_as.on "error", (err) ->
                console.warn "error executing #{llvm_commands['llvm-as']}: #{err}"
                process.exit -1
        llvm_as.on "exit", (code) ->
                debug.log 1, "executing `#{llvm_commands['opt']} #{opt_args.join ' '}'"
                opt = spawn llvm_commands['opt'], opt_args
                opt.stderr.on "data", (data) -> console.warn "#{data}"
                opt.on "error", (err) ->
                        console.warn "error executing #{llvm_commands['opt']}: #{err}"
                        process.exit -1
                opt.on "exit", (code) ->
                        debug.log 1, "executing `#{llvm_commands['llc']} #{llc_args.join ' '}'"
                        llc = spawn llvm_commands['llc'], llc_args
                        llc.stderr.on "data", (data) -> console.warn "#{data}"
                        llc.on "error", (err) ->
                                console.warn "error executing #{llvm_commands['llc']}: #{err}"
                                process.exit -1
                        llc.on "exit", (code) ->
                                o_filenames.push o_filename
                                compileCallback()

relative_to_ejs_exe = (n) ->
        path.resolve (path.dirname process.argv[if __ejs? then 0 else 1]), n


generate_import_map = (js_modules, native_modules) ->
        sanitize = (filename, c_callable) ->
                filename = filename.replace /\.js$/, ""
                if c_callable
                        filename = filename.replace /[.,-\/\\]/g, "_" # this is insanely inadequate
                filename

        map_path = "#{os.tmpdir()}/#{util.genFreshFileName path.basename main_file}-modules.cpp"

        map_contents = "#include \"#{relative_to_ejs_exe '../../runtime/ejs-module.h'}\"\n"
        map_contents += "extern \"C\" {\n"

        js_modules.forEach (m) ->
                map_contents += "extern EJSModule #{m.module_name};\n"
                map_contents += "extern ejsval #{m.toplevel_function_name} (ejsval env, ejsval _this, uint32_t argc, ejsval* arg);\n"

        map_contents += "EJSModule* _ejs_modules[] = {\n"
        js_modules.forEach (m) ->
                map_contents += "  &#{m.module_name},\n"
        map_contents += "};\n"

        map_contents += "ejsval (*_ejs_module_toplevels[])(ejsval, ejsval, uint32_t, ejsval*) = {\n"
        js_modules.forEach (m) ->
                map_contents += " #{m.toplevel_function_name},\n"
        map_contents += "};\n"
        map_contents += "int _ejs_num_modules = sizeof(_ejs_modules) / sizeof(_ejs_modules[0]);\n\n"

        native_modules.forEach ({ init_function }) ->
                map_contents += "extern ejsval #{init_function} (ejsval exports);\n"
        map_contents += "EJSExternalModule _ejs_external_modules[] = {\n"
        native_modules.forEach ({ module_name, init_function }) ->
                map_contents += "  { \"@#{module_name}\", #{init_function}, 0 },\n"
        map_contents += "};\n"
        map_contents += "int _ejs_num_external_modules = sizeof(_ejs_external_modules) / sizeof(_ejs_external_modules[0]);\n"

        entry_module = file_args[0]
        if entry_module.lastIndexOf(".js") == entry_module.length - 3
                entry_module = entry_module.substring(0, entry_module.length-3)
        map_contents += "const EJSModule* entry_module = &#{js_modules.get(entry_module).module_name};\n"

        map_contents += "};"

        fs.writeFileSync(map_path, map_contents)
        
        temp_files.push map_path

        map_path

do_final_link = (main_file, modules) ->
        js_modules = new Map()
        native_modules = new Map()
        
        modules.forEach (m,k) ->
                if m.isNative()
                        native_modules.set(k, m)
                else
                        js_modules.set(k, m)
        
        map_filename = generate_import_map(js_modules, native_modules)
        
        process.env.PATH = "#{target_path_prepend(options.target_platform,options.target_arch)}:#{process.env.PATH}"

        output_filename = options.output_filename || "#{main_file}.exe"
        clang_args = target_link_args(options.target_platform, options.target_arch).concat ["-DEJS_BITS_PER_WORD=#{options.target_pointer_size}", "-o", output_filename].concat o_filenames
        if arch_info[options.target_arch].little_endian
                clang_args.unshift("-DIS_LITTLE_ENDIAN=1")
                
        # XXX we shouldn't need this, but build is failing while compiling the require map
        clang_args.push "-I."
        
        clang_args.push map_filename
        
        clang_args.push relative_to_ejs_exe target_libecho(options.target_platform, options.target_arch)
        clang_args.push relative_to_ejs_exe target_extra_libs(options.target_platform, options.target_arch)

        seen_native_modules = new Set()
        native_modules.forEach (module) ->
                module.module_files.forEach (mf) ->
                        return if seen_native_modules.has(mf) # don't include native modules more than once
                        seen_native_modules.add(mf)
                
                        clang_args.push mf

                # very strange, not sure why we need this \n
                clang_args = clang_args.concat module.link_flags.replace('\n', ' ').split(" ")

        clang_args = clang_args.concat target_libraries(options.target_platform, options.target_arch)

        console.warn "#{util.bold()}LINK#{util.reset()} #{output_filename}" if not options.quiet
        
        debug.log 1, "executing `#{target_linker} #{clang_args.join ' '}'"
        
        clang = spawn target_linker, clang_args
        clang.stderr.on "data", (data) -> console.warn "#{data}"
        clang.on "exit", (code) ->
                if not options.leave_temp_files
                        cleanup ->
                                console.warn "#{util.bold()}done.#{util.reset()}" if not options.quiet

cleanup = (done) ->
        files_to_delete = temp_files.length
        temp_files.forEach (filename) ->
                fs.unlink filename, (err) ->
                        files_to_delete = files_to_delete - 1
                        done() if files_to_delete is 0
                
main_file = file_args[0]
files = compiler.gatherAllModules(file_args, options)
debug.log 1, -> compiler.dumpModules()
allModules = compiler.getAllModules()

# now compile them
#
# reverse the list so the main program is the first thing we compile
files.reverse()
compileNextFile = ->
        if files.length is 0
                do_final_link(main_file, allModules)
                return
        f = files.pop()
        compileFile f.file_name, f.file_ast, allModules, compileNextFile
compileNextFile()
        
# Local Variables:
# mode: coffee
# End:
