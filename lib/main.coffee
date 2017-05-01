fs = require 'fs'
async = require 'async'
nodePath = require 'path'
AWSUtils = require './aws'
inquirer = require 'inquirer'
download = require 'download-github-repo'
CommUtils = require './comm'
LambdaUtils = require './lambda'
TopologyUtils = require './topology'
SimulationUtils = require './simulation/simulation'

Attak =
  utils:
    aws: AWSUtils
    comm: CommUtils
    lambda: LambdaUtils
    topology: TopologyUtils
    simulation: SimulationUtils

  init: (program, callback) ->
    console.log "INIT"
    workingDir = program.cwd || process.cwd()

    questions = [{
      type: 'input',
      name: 'name',
      message: 'Project name?'
      default: 'attak-hello-world'
    }]

    inquirer.prompt questions
      .then (answers) ->
        path = "#{workingDir}/#{answers.name}"
        console.log "FULL PATH", path
        
        if not fs.existsSync path
          fs.mkdirSync path

        download "attak/attak-hello-world", path, ->
          console.log "DONE", arguments
          callback()
      .catch (err) ->
        console.log "CAUGHT ERROR", err

  simulate: (program, callback) ->
    topology = TopologyUtils.loadTopology program

    program.startTime = new Date
    program.environment = program.environment || 'development'

    if program.input
      input = program.input
    else
      inputPath = nodePath.resolve (program.cwd || process.cwd()), program.inputFile
      if fs.existsSync inputPath
        input = require inputPath
      else
        input = undefined

    if program.id
      CommUtils.connect program, (socket, wrtc) ->
        wrtc.emit 'topology',
          topology: topology

        emitter = wrtc.emit
        wrtc.reconnect = (wrtc) ->
          emitter = wrtc.emit

        opts =
          report: () ->
            emitter? arguments...

        SimulationUtils.runSimulations program, topology, input, opts, callback

    else
      SimulationUtils.runSimulations program, topology, input, {}, callback

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

  deploy: (opts, callback) ->
    topology = TopologyUtils.loadTopology opts

    async.waterfall [
      (done) ->
        if opts.skip?.processors
          LambdaUtils.getProcessorInfo topology, opts, (err, lambdas) ->
            results = {lambdas}
            done err, results
        else
          LambdaUtils.deployProcessors topology, opts, (err, lambdas) ->
            results = {lambdas}
            done err, results
      (results, done) ->
        console.log "DEPLOY STREAMS", results
        if opts.skip?.streams
          return done null, results

        {lambdas} = results
        AWSUtils.deployStreams topology, opts, lambdas, (err, streams) ->
          results.streams = streams
          done null, results
      (results, done) ->
        if opts.skip?.config
          return done null, results

        async.parallel [
          (done) ->
            if topology.api
              gatewayOpts =
                name: "#{topology.name}-#{opts.environment || 'development'}"
                environment: opts.environment

              AWSUtils.setupGateway topology.api, gatewayOpts, (err, results) ->
                results.gateway = results
                done err
            else
              done()
          (done) ->
            if topology.schedule
              AWSUtils.setupSchedule topology, opts, (err, results) ->
                done err
            else
              done()
          (done) ->
            if topology.static
              AWSUtils.setupStatic topology, opts, (err, results) ->
                done err
            else
              done()
        ], (err) ->
          done err, results
      (results, done) ->
        if opts.skip?.provision or !topology.provision
          return done null, results

        config =
          aws:
            endpoints: {}

        topology.provision topology, config, (err) ->
          done err, results
    ], (err, results) ->
      callback? err, results

module.exports = Attak