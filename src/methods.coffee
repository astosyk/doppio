
# pull in external modules
_ = require '../vendor/_.js'
util = require './util'
opcodes = require './opcodes'
attributes = require './attributes'
natives = require './natives'
runtime = require './runtime'
logging = require './logging'
jvm = require './jvm'
{vtrace,trace,debug_vars} = logging
{ReturnException} = require './exceptions'
{native_methods,trapped_methods} = natives
{JavaArray,JavaObject} = require './java_object'

"use strict"

# things assigned to root will be available outside this module
root = exports ? this.methods = {}

class AbstractMethodField
  # Subclasses need to implement parse_descriptor(String)
  constructor: (@cls) ->

  parse: (bytes_array,constant_pool,@idx) ->
    @access_byte = bytes_array.get_uint 2
    @access_flags = util.parse_flags @access_byte
    @name = constant_pool.get(bytes_array.get_uint 2).value
    @raw_descriptor = constant_pool.get(bytes_array.get_uint 2).value
    @parse_descriptor @raw_descriptor
    @attrs = attributes.make_attributes(bytes_array,constant_pool)

  get_attribute: (name) ->
    for attr in @attrs then if attr.name is name then return attr
    return null

  get_attributes: (name) -> attr for attr in @attrs when attr.name is name

class root.Field extends AbstractMethodField
  parse_descriptor: (raw_descriptor) ->
    @type = raw_descriptor

  # Must be called asynchronously.
  reflector: (rs, success_fn, failure_fn) ->
    # note: sig is the generic type parameter (if one exists), not the full
    # field type.
    sig = _.find(@attrs, (a) -> a.name == "Signature")?.sig

    create_obj = (clazz_obj, type_obj) =>
      new JavaObject rs, rs.get_bs_class('Ljava/lang/reflect/Field;'), {
        # XXX this leaves out 'annotations'
        'Ljava/lang/reflect/Field;clazz': clazz_obj
        'Ljava/lang/reflect/Field;name': rs.init_string @name, true
        'Ljava/lang/reflect/Field;type': type_obj
        'Ljava/lang/reflect/Field;modifiers': @access_byte
        'Ljava/lang/reflect/Field;slot': @idx
        'Ljava/lang/reflect/Field;signature': if sig? then rs.init_string sig else null
      }

    clazz_obj = @cls.get_class_object(rs)
    # type_obj may not be loaded, so we asynchronously load it here.
    # In the future, we can speed up reflection by having a synchronous_reflector
    # method that we can try first, and which may fail.
    @cls.loader.resolve_class rs, @type, ((type_cls) =>
      type_obj = type_cls.get_class_object(rs)
      rv = create_obj clazz_obj, type_obj
      success_fn rv
    ), failure_fn
    return

class root.Method extends AbstractMethodField
  parse_descriptor: (raw_descriptor) ->
    @reset_caches = false # Switched to 'true' in web frontend between JVM invocations.
    [__,param_str,return_str] = /\(([^)]*)\)(.*)/.exec(raw_descriptor)
    param_carr = param_str.split ''
    @param_types = (field while (field = util.carr2descriptor param_carr))
    @param_bytes = 0
    for p in @param_types
      @param_bytes += if p in ['D','J'] then 2 else 1
    @param_bytes++ unless @access_flags.static
    @num_args = @param_types.length
    @num_args++ unless @access_flags.static # nonstatic methods get 'this'
    @return_type = return_str

  full_signature: -> "#{@cls.get_type()}::#{@name}#{@raw_descriptor}"

  parse: (bytes_array, constant_pool, idx) ->
    super bytes_array, constant_pool, idx
    sig = @full_signature()
    if (c = trapped_methods[sig])?
      @code = c
      @access_flags.native = true
    else if @access_flags.native
      if (c = native_methods[sig])?
        @code = c
      else
        console.log(sig) if jvm.show_NYI_natives and sig.indexOf('::registerNatives()V',1) < 0 and sig.indexOf('::initIDs()V',1) < 0
        if UNSAFE?
          @code = null # optimization: avoid copying around params if it is a no-op.
        else
          @code = (rs) =>
            unless sig.indexOf('::registerNatives()V',1) >= 0 or sig.indexOf('::initIDs()V',1) >= 0
              rs.java_throw rs.get_bs_class('Ljava/lang/Error;'), "native method NYI: #{sig}"
    else
      @has_bytecode = true
      @code = _.find(@attrs, (a) -> a.name == 'Code')

  reflector: (rs, is_constructor=false, success_fn, failure_fn) ->
    typestr = if is_constructor then 'Ljava/lang/reflect/Constructor;' else 'Ljava/lang/reflect/Method;'
    exceptions = _.find(@attrs, (a) -> a.name == 'Exceptions')?.exceptions ? []
    anns = _.find(@attrs, (a) -> a.name == 'RuntimeVisibleAnnotations')?.raw_bytes
    adefs = _.find(@attrs, (a) -> a.name == 'AnnotationDefault')?.raw_bytes
    sig =  _.find(@attrs, (a) -> a.name == 'Signature')?.sig
    obj = {}

    clazz_obj = @cls.get_class_object(rs)

    @cls.loader.resolve_class(rs, @return_type, ((rt_cls) =>
      rt_obj = rt_cls.get_class_object(rs)
      j = -1
      etype_objs = []
      i = -1
      param_type_objs = []
      fetch_etype = () =>
        j++
        if j < exceptions.length
          e_desc = exceptions[j]
          @cls.loader.resolve_class(rs, e_desc,
            ((cls)=>etype_objs[j]=cls.get_class_object(rs);fetch_etype()), failure_fn)
        else
          # XXX: missing parameterAnnotations
          obj[typestr + 'clazz'] = clazz_obj
          obj[typestr + 'name'] = rs.init_string @name, true
          obj[typestr + 'parameterTypes'] = new JavaArray rs, rs.get_bs_class('[Ljava/lang/Class;'), param_type_objs
          obj[typestr + 'returnType'] = rt_obj
          obj[typestr + 'exceptionTypes'] = new JavaArray rs, rs.get_bs_class('[Ljava/lang/Class;'), etype_objs
          obj[typestr + 'modifiers'] = @access_byte
          obj[typestr + 'slot'] = @idx
          obj[typestr + 'signature'] = if sig? then rs.init_string sig else null
          obj[typestr + 'annotations'] = if anns? then new JavaArray(rs, rs.get_bs_class('[B'), anns) else null
          obj[typestr + 'annotationDefault'] = if adefs? then new JavaArray(rs, rs.get_bs_class('[B'), adefs) else null
          success_fn(new JavaObject rs, rs.get_bs_class(typestr), obj)

      fetch_ptype = () =>
        i++
        if i < @param_types.length
          @cls.loader.resolve_class(rs, @param_types[i],
            ((cls)=>param_type_objs[i]=cls.get_class_object(rs);fetch_ptype()), failure_fn)
        else
          fetch_etype()

      fetch_ptype()
    ), failure_fn)

  take_params: (caller_stack) ->
    start = caller_stack.length - @param_bytes
    params = caller_stack.slice(start)
    # this is faster than splice()
    caller_stack.length -= @param_bytes
    params

  RELEASE? || padding = '' # used in debug mode to align instruction traces

  convert_params: (rs, params) ->
    converted_params = [rs]
    param_idx = 0
    if not @access_flags.static
      converted_params.push params[0]
      param_idx = 1
    for p in @param_types
      converted_params.push params[param_idx]
      param_idx += if (p in ['J', 'D']) then 2 else 1
    converted_params

  run_manually: (func, rs, converted_params) ->
    trace "entering native method #{@full_signature()}"
    try
      rv = func converted_params...
    catch e
      return if e is ReturnException
      throw e
    rs.meta_stack().pop()
    ret_type = @return_type
    unless ret_type == 'V'
      if ret_type == 'Z' then rs.push rv + 0 # cast booleans to a Number
      else rs.push rv
      rs.push null if ret_type in [ 'J', 'D' ]

  # Reinitializes the method by removing all cached information from the method.
  # We amortize the cost by doing it lazily the first time that we call run_bytecode.
  initialize: -> @reset_caches = true

  run_bytecode: (rs) ->
    trace "entering method #{@full_signature()}"
    if @reset_caches and @code?.opcodes?
      for instr in @code.opcodes
        instr?.reset_cache()
    # main eval loop: execute each opcode, using the pc to iterate through
    code = @code.opcodes
    cf = rs.curr_frame()
    try
      while true
        op = code[cf.pc]
        unless RELEASE? or logging.log_level < logging.STRACE
          pc = cf.pc
          throw "#{@name}:#{pc} => (null)" unless op
          vtrace "#{padding}stack: [#{debug_vars cf.stack}], local: [#{debug_vars cf.locals}]"
          annotation = op.annotate(pc, @cls.constant_pool)
          vtrace "#{padding}#{@cls.get_type()}::#{@name}:#{pc} => #{op.name}" + annotation

        cf.pc += 1 + op.byte_count if (op.execute rs) isnt false
    catch e
      return if e is ReturnException
      throw e
    # Must explicitly return here, to avoid Coffeescript accumulating an array of cf.pc values
    return

  setup_stack: (runtime_state) ->
    ms = runtime_state.meta_stack()
    caller_stack = runtime_state.curr_frame().stack
    params = @take_params caller_stack

    if @access_flags.native
      if @code?
        ms.push(sf = new runtime.StackFrame(this,[],[]))
        c_params = @convert_params runtime_state, params
        sf.runner = => @run_manually @code, runtime_state, c_params
        return sf
      return

    if @access_flags.abstract
      runtime_state.java_throw rs.get_bs_class('Ljava/lang/Error;'), "called abstract method: #{@full_signature()}"

    # Finally, the normal case: running a Java method
    ms.push(sf = new runtime.StackFrame(this,params,[]))
    if @code.run_stamp < runtime_state.run_stamp
      @code.run_stamp = runtime_state.run_stamp
      @code.parse_code()
    sf.runner = => @run_bytecode runtime_state
    return sf
