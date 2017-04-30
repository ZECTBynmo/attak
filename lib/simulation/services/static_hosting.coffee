BaseService = require '../base_service'

class StaticHosting extends BaseService

  paths: [
    'AWS:S3'
    'GCE:CloudStorage'
  ]

  setup: (topology, opts, callback) ->
    workingDir = opts.cwd || process.cwd()
    hostname = '127.0.0.1'
    port = opts.port || 12342

    if topology.static.constructor is String
      staticDir = nodePath.resolve workingDir, topology.static
    else
      staticDir = nodePath.resolve workingDir, topology.static.dir

    file = new staticHost.Server staticDir

    server = http.createServer (req, res) ->
      req.addListener 'end', ->
        file.serve req, res
      .resume()
    
    server.listen port, hostname, ->
      opts.report?.info "Static files hosted at: http://localhost:#{port}/[file path]"
        # console.log "Externally visible url: #{url}/[file [path]"
      callback null, "http://localhost:#{port}"

module.exports = StaticHosting