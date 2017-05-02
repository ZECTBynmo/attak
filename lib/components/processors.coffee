AWS = require 'aws-sdk'
async = require 'async'
AWSUtils = require '../aws'
AttakProc = require 'attak-processor'
LambdaUtils = require '../lambda'
BaseComponent = require './base_component'
TopologyUtils = require '../topology'
SimulationUtils = require '../simulation/simulation'

class Processors extends BaseComponent
  namespace: 'processors'
  platforms: ['AWS']
  dependencies: ['name']
  simulation:
    services: ->
      'AWS:API':
        handlers:
          "POST /:apiVerison/functions/:functionName/invoke-async": @handleInvoke
          "GET /:apiVerison/functions/:functionName": @handleGetFunction
          "POST /:apiVerison/functions": @handleCreateFunction
          "PUT /:apiVerison/functions": @handleCreateFunction
      'AWS:Kinesis':
        handlers:
          "POST /": @handleKinesisPut

  fetchState: (callback) ->
    state = {}

    lambda = new AWS.Lambda
      region: @options.region || 'us-east-1'

    @getAllFunctions lambda, (err, functions) =>
      if err then return callback(err)

      for fn in functions
        if fn.Environment?.Variables?.ATTAK_TOPOLOGY_NAME is @options.topology.name
          state[fn.Environment.Variables.ATTAK_PROCESSOR_NAME] = fn

      callback err, state

  getAllFunctions: (lambda, callback) ->
    marker = undefined
    functions = []
    
    async.doWhilst (done) ->
      params =
        MaxItems: 200
        Marker: marker

      lambda.listFunctions params, (err, results) ->
        if err then return done(err)
        
        marker = results.NextMarker
        for data in results.Functions
          functions.push data

        done()
    , () ->
      marker?
    , (err, numPages) ->
      callback err, functions

  # create: (path, newDefs, opts) ->
  resolveState: (currentState, newState, diffs, opts, callback) ->
    opts =
      name: opts.dependencies.name
      services: opts.services
      simulation: true
      processors: newState

    LambdaUtils.deployProcessors opts, (err, processors) ->
      console.log "DONE DEPLOY", err, processors
      callback err

  update: (path, oldDefs, newDefs, opts) ->
    console.log "UPDATING PROCESSOR", path[0], oldDefs, newDefs
    @state[path[0]] = newDefs
    callback null

  delete: (path, oldDefs, opts) ->
    console.log "REMOVING PROCESSOR", path[0], oldDefs
    delete @state[path[0]]
    callback null

  handleInvoke: (state, opts, req, res) =>
    environment = opts.environment || 'development'

    splitPath = req.url.split '/'
    fullName = splitPath[3]
    processorName = fullName.split("-#{environment}")[0]
    @invokeProcessor processorName, req.body, state, opts, (err, results) ->
      if err
        res.status(500).send err
      else
        res.send results.body

  invokeProcessor: (processorName, data, state, opts, callback) ->
    context =
      done: -> callback()
      fail: (err) -> callback err
      success: (results) -> callback null, results
      state: state
      services: opts.services

    processor = TopologyUtils.getProcessor opts, state, processorName
    handler = AttakProc.handler processorName, state, processor, opts
    handler data, context, (err, results) ->
      callback err, results

  handleCreateFunction: (state, opts, req, res) ->
    console.log "HANDLING CREATE FUNCTION", opts, req.method, req.url, req.params

    name = req.params.functionName
    req.on 'data', -> null
    req.on 'end', ->
      res.json
        FunctionName: name
        FunctionArn: "arn:aws:lambda:us-east-1:133713371337:function:#{name}"
        Runtime: 'nodejs4.3'
        Role: 'arn:aws:iam::133713371337:role/lambda'
        CodeSize: 8469826
        Version: '$LATEST'
        TracingConfig: Mode: 'PassThrough'

  handleGetFunction: (state, opts, req, res) ->
    console.log "HANDLING GET FUNCTION", opts, req.method, req.url, req.params, state.processors
    name = req.params.functionName

    if state.processors?[name] is undefined
      res.status 400
      res.header 'x-amzn-errortype', 'ResourceNotFoundException'
      res.json
        message: "Function not found: arn:aws:lambda:us-east-1:133713371337:function:#{name}"
        code: 'ResourceNotFoundException'
    else
      res.json
        Configuration: 
          FunctionName: 'lamprey-production'
          FunctionArn: 'arn:aws:lambda:us-east-1:133713371337:function:lamprey-production'
          Runtime: 'nodejs4.3'
          Role: 'arn:aws:iam::133713371337:role/lambda'
          Handler: 'attak_runner.handler'
          CodeSize: 5245616
          Description: ''
          Timeout: 3
          MemorySize: 512
          LastModified: '2016-06-13T05:08:43.436+0000'
          CodeSha256: 'fEHreHoyS2q8/9dttxsvO/YlHBJ0YMDR6HYhMTlpylo='
          Version: '$LATEST'
          KMSKeyArn: null
          TracingConfig:
            Mode: 'PassThrough'
        Code: 
          RepositoryType: 'S3'
          Location: "https://prod-04-2014-tasks.s3.amazonaws.com/snapshots/133713371337/#{name}-#{uuid.v1()}"

  getTargetProcessor: (state, targetStream) ->
    for stream in state.streams
      streamName = AWSUtils.getStreamName state.name, stream.from, stream.to
      console.log "STREAM NAME", streamName, "LOOKING FOR", targetStream
      if streamName is targetStream
        return stream.to

  handleKinesisPut: (state, opts, req, res) =>
    console.log "HANDLE KINESIS PUT", req.body.StreamName
    
    processorName = @getTargetProcessor state, req.body.StreamName
    data = JSON.parse new Buffer(req.body.Data, 'base64').toString()
    @invokeProcessor processorName, data.data, state, opts, (err, results) ->
      res.json {ok: true}

module.exports = Processors