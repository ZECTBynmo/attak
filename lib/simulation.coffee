AWS = require 'aws-sdk'
uuid = require 'uuid'
chalk = require 'chalk'
async = require 'async'
AWSUtils = require './aws'
AttakProc = require 'attak-processor'
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
      kinesisEndpoint: program.kinesisEndpoint

    kinesis = new AWS.Kinesis
      region: program.region || 'us-east-1'
      endpoint: program.kinesisEndpoint

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

    async.eachOf input, (data, processor, next) ->
      eventQueue = [{processor: processor, input: data}]
      procName = undefined
      simData = undefined
      async.whilst () ->
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
          allResults[procName].callback = {err, results}

          done err
      , (err) ->
        next()
    , (err) ->
      callback? err, allResults

module.exports = SimulationUtils