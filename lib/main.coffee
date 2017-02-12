chalk = require 'chalk'
async = require 'async'
nodePath = require 'path'
AWSUtils = require './aws'
LambdaUtils = require './lambda'

module.exports =
  version: '0.0.1'

  simulate: (program, callback) ->
    CommUtils = require './comm'
    CommUtils.connect program, (socket, wrtc) ->
      topology = program.topology || require (program.cwd || process.cwd())

      wrtc.emit 'topology',
        topology: topology

      inputPath = nodePath.resolve (program.cwd || process.cwd()), program.inputFile
      input = topology.input || require inputPath

      allResults = {}

      async.eachOf input, (data, processor, next) ->
        runSimulation = (procName, simData, isTopLevel=true) ->
          AWSUtils.simulate program, topology, procName, simData, (topic, emitData, opts) ->
            report = program.report || wrtc.emit || () ->
              console.log chalk.blue("#{procName} : #{topic}", arguments...)

            report 'emit',
              data: emitData            
              processor: processor
            
            if allResults[procName] is undefined
              allResults[procName] = {}
            allResults[procName][topic] = emitData
            for stream in topology.streams
              if stream.from is procName and (stream.topic || topic) is topic
                runSimulation stream.to, emitData, false
          
          , (err, results) ->
            if isTopLevel
              next()

        runSimulation processor, data
      , (err) ->
        callback? err, allResults

  trigger: (program, callback) ->
    topology = require (program.cwd || process.cwd())
    inputPath = nodePath.resolve (program.cwd || process.cwd()), program.inputFile
    input = topology.input || require inputPath

    program.startTime = new Date

    async.eachOf input, (data, processor, next) ->      
      AWSUtils.triggerProcessor program, processor, data, (err, results) ->
        next()
    , (err) ->
      async.eachOf topology.processors, (procData, procName, nextProc) ->
        AWSUtils.monitorLogs program, procName, (err, results) ->
          nextProc()
      , ->
        callback? err

  deploy: (program, callback) ->
    topology = require (program.cwd || process.cwd())

    if topology.name is undefined
      throw new Error 'topology.name is undefined'

    LambdaUtils.deployProcessors topology, program, (err, lambdas) ->
      AWSUtils.deployStreams topology, program, lambdas, (err, streams) ->
        callback? err, {lambdas, streams}