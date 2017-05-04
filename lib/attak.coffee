fs = require 'fs'
async = require 'async'
extend = require 'extend'
nodePath = require 'path'
Processors = require './components/processors'
TopologyUtils = require './topology'
BaseComponent = require './components/base_component'

class ATTAK extends BaseComponent
  namespace: 'ATTAK'

  defaultComponents:
    api: require './components/api'
    name: require './components/name'
    streams: require './components/streams'
    processors: require './components/processors'

  constructor: (@options={}) ->
    super @options
    @topology = @options.topology
    @dependencies = @options.dependencies || []
    components = extend @defaultComponents, @topology.components || {}
    allComponents = extend @options.children || {}, components

    @children = {}
    for key, Component of allComponents
      child = new Component extend @options,
        path: [key]
      @addChild key, child

  getDepValues: (component, state) ->
    deps = component.constructor::dependencies
    if deps?.constructor is Array
      objDeps = {}
      for dep in deps
        objDeps[dep] = {}
      deps = objDeps

    retval = {}

    for key, val of deps
      splitKey = key.split '/'

      if val is true or val.value is undefined
        stateVal = state
        for item in splitKey
          stateVal = stateVal?[item]
        retval[key] = stateVal
      else if val.value.constructor is Function
        stateVal = state
        for item in splitKey
          if item.indexOf(':') is -1
            stateVal = stateVal?[item]
          else
            for stateKey, stateData of stateVal
              if stateKey is item.split(':')[1]
                null

    retval

  setState: (currentState, newState, opts, callback) ->
    keys = Object.keys(currentState)
    for key, val of newState
      if key not in keys
        keys.push key

    async.each keys, (key, next) =>
      component = @children[key]
      current = currentState[key] || {}
      target = newState[key] || {}
      opts.target = newState

      opts.dependencies = @getDepValues component, newState
      component.setState current, target, opts, (err, results) =>
        if opts.updatedState
          newState = extend newState, opts.updatedState
          @saveState newState
        next err
    , (err) =>
      @saveState newState, @path
      callback err

  handleDiff: (diff, opts) ->
    async.forEachOf diff.rhs, (val, key, next) =>
      component = @children[key]
      if component is undefined
        return next new Error "No component for namespace #{key}"

      component.setState val, ->
        next()
    , (err) ->
      callback err

module.exports = ATTAK