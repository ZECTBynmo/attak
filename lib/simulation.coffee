AWS = require 'aws-sdk'
http = require 'http'
uuid = require 'uuid'
ngrok = require 'ngrok'
chalk = require 'chalk'
async = require 'async'
nodePath = require 'path'
dynalite = require 'dynalite'
AWSUtils = require './aws'
AttakProc = require 'attak-processor'
kinesalite = require 'kinesalite'
TopologyUtils = require './topology'

SimulationUtils =

  defaultReport: (eventName, event) ->
    switch eventName
      when 'emit'
        console.log chalk.blue("emit #{event.processor} : #{event.topic}", JSON.stringify(event.data))
      when 'start'
        console.log chalk.blue("start #{event.processor}")
      when 'end'
        console.log chalk.blue("end #{event.processor} : #{event.end - event.start} ms")
      when 'err'
        console.log chalk.blue("#{eventName} #{event.processor} #{event.err.stack}")
      else
        console.log chalk.blue("#{eventName} #{event.processor} #{JSON.stringify(event)}")

  simulate: (program, topology, processorName, data, report, triggerId, emitCallback, callback) ->
    results = {}
    workingDir = program.cwd || process.cwd()
    
    processor = TopologyUtils.getProcessor program, topology, processorName

    context =
      done: -> callback()
      fail: (err) -> callback err
      success: (results) -> callback null, results
      topology: topology
      endpoints: program.endpoints

    kinesis = new AWS.Kinesis
      region: program.region || 'us-east-1'
      endpoint: program.endpoints.kinesis

    nextByTopic = AWSUtils.nextByTopic topology, processorName
    AWSUtils.getIterators kinesis, processorName, nextByTopic, topology, (err, iterators) ->
      startTime = new Date().getTime()

      report 'start',
        processor: processorName
        triggerId: triggerId
        start: startTime

      handler = AttakProc.handler processorName, topology, processor, program
      handler data, context, (err, resultData) ->
        endTime = new Date().getTime()

        if err
          report 'err',
            processor: processorName
            triggerId: triggerId
            start: startTime
            end: endTime
            err: err

          return callback err

        report 'end',
          processor: processorName
          triggerId: triggerId
          start: startTime
          end: endTime

        async.forEachOf nextByTopic, (nextProc, topic, done) ->
          streamName = AWSUtils.getStreamName topology.name, processorName, nextProc
          iterator = iterators[streamName]

          kinesis.getRecords
            ShardIterator: iterator.ShardIterator
          , (err, rawRecords) ->
            iterators[streamName] =
              ShardIterator: rawRecords.NextShardIterator

            records = []
            for record in rawRecords.Records
              dataString = new Buffer(record.Data, 'base64').toString()
              records.push JSON.parse dataString

            for record in records
              emitCallback record.topic, record.data, record.opts

            done err
        , (err) ->
          callback err, resultData

  runSimulations: (program, topology, input, simOpts, callback) ->
    allResults = {}
    SimulationUtils.setupSimulationDeps allResults, program, topology, input, simOpts, (err, endpoints) ->
      program.endpoints = endpoints

      AWSUtils.deploySimulationStreams program, topology, (streamNames) ->
        async.eachOf input, (data, processor, next) ->
          SimulationUtils.runSimulation allResults, program, topology, input, simOpts, data, processor, ->
            next()
        , (err) ->
          if topology.api
            console.log "Waiting for incoming requests"
          else
            callback? err, allResults

  setupSimulationDeps: (allResults, program, topology, input, simOpts, callback) ->
    endpoints = {}

    async.parallel [
      (done) ->
        kinesaliteServer = kinesalite
          path: nodePath.resolve __dirname, '../dynamodb'
          createStreamMs: 0

        kinesaliteServer.listen 6668, (err) ->
          endpoints.kinesis = 'http://localhost:6668'
          done()

      (done) ->
        dynaliteServer = dynalite
          path: nodePath.resolve __dirname, '../kinesisdb'
          createStreamMs: 0

        dynaliteServer.listen 6698, (err) ->
          endpoints.dynamodb = 'http://localhost:6698'
          done()

      (done) ->
        if topology.api
          SimulationUtils.spoofApi allResults, program, topology, input, simOpts, (err, url) ->
            endpoints.api = url
            done err
        else
          done()
    ], (err) ->
      callback err, endpoints
    
  spoofApi: (allResults, program, topology, input, simOpts, callback) ->
    hostname = '127.0.0.1'
    port = 12369
    
    server = http.createServer (req, res) ->
      if program.endpoints is undefined
        return res.end()

      event =
        path: req.url
        body: req.body
        headers: req.headers
        httpMethod: req.method
        queryStringParameters: req.query

      SimulationUtils.runSimulation allResults, program, topology, input, simOpts, event, topology.api, ->
        if allResults[topology.api]?.callback.err
          res.writeHead 500
          return res.end allResults[topology.api]?.callback.err.stack

        response = allResults[topology.api]?.callback?.results?.body || ''
        if not response
          return res.end()

        try
          respData = JSON.parse response
          if respData.status or respData.httpStatus or respData.headers
            res.writeHead (respData.status || respData.httpStatus || 200), respData.headers
          res.end respData
        catch e
          res.end response
    
    server.listen port, hostname, ->
      ngrok.connect port, (err, url) ->
        console.log "API running at: http://localhost:#{port}"
        console.log "Externally visible url:", url
        callback null, "http://localhost:#{port}"

  runSimulation: (allResults, program, topology, input, simOpts, data, processor, callback) ->
    eventQueue = [{processor: processor, input: data}]
    hasError = false
    procName = undefined
    simData = undefined
    async.whilst () ->
      if hasError then return false

      nextEvent = eventQueue.shift()
      procName = nextEvent?.processor
      simData = nextEvent?.input
      return nextEvent?
    , (done) ->
      numEmitted = 0
      triggerId = uuid.v1()
      report = program.report || simOpts?.report || SimulationUtils.defaultReport

      if allResults[procName] is undefined
        allResults[procName] =
          emits: {}

      SimulationUtils.simulate program, topology, procName, simData, report, triggerId, (topic, emitData, opts) ->
        numEmitted += 1

        report 'emit',
          data: emitData
          topic: topic
          trace: simData.trace || uuid.v1()
          emitId: uuid.v1()
          triggerId: triggerId
          processor: procName

        if allResults[procName].emits[topic] is undefined
          allResults[procName].emits[topic] = []

        allResults[procName].emits[topic].push emitData
        if allResults[procName].emits[topic].length > 1000
          allResults[procName].emits[topic].shift()

        for stream in topology.streams
          if stream.from is procName and (stream.topic || topic) is topic
            eventQueue.push
              processor: stream.to
              input: emitData

      , (err, results) ->
        if err
          hasError = true

        if allResults[procName] is undefined
          allResults[procName] = {}
        allResults[procName].callback = {err, results}

        done err
    , (err) ->
      callback()

module.exports = SimulationUtils