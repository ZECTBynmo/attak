extend = require 'extend'
express = require 'express'

rawFields = ['string']

class ComponentManager

  constructor: () ->
    @router = new express.Router
    @listeners = {}
    @components = {}

  add: (component) ->
    @components[component.guid] = component
    @listeners[component.guid] = (req, res, next) =>
      plan = req.body.plan
      params = req.params

      res.handle component, params, plan, (err, results) =>
        next()

    structure = component.structure

    flattened = @flattenObject structure
    for urlPath, subscribeTo of flattened
      changeUrl = "/#{component.namespace}/#{urlPath}"
      @router.all subscribeTo, @listeners[component.guid]

  remove: (guid) ->
    delete @components[guid]

  notifyChange: (fromNamespace, path, plan, oldState, newState, diffs, opts, callback) ->
    if opts.preventNotify
      return callback null, plan

    response =
      handle: (component, params, plan, nextHandler) =>
        notifyOpts = extend true, {}, opts
        notifyOpts.preventNotify = true
        notifyOpts.fromNamespace = fromNamespace

        component.planResolution oldState, newState, diffs, notifyOpts, plan, (err, newPlan) ->
          if err then return callback err, plan
          
          plan = newPlan
          nextHandler()

    request =
      method: 'POST'
      body:
        plan: plan
        path: path
        oldState: oldState
        newState: newState
      url: "/#{path.join '/'}"

    @router.handle request, response, (err) ->
      callback err, plan

  flattenObject: (ob) ->
    what = Object.prototype.toString
    toReturn = {}
    for i of ob
      if !ob.hasOwnProperty(i)
        continue
      result = what.call(ob[i])
      if result == '[object Object]' or result == '[object Array]'
        flatObject = @flattenObject(ob[i])
        for x of flatObject
          if !flatObject.hasOwnProperty(x)
            continue
          toReturn[i + '/' + x] = flatObject[x]
      else
        toReturn[i] = ob[i]
    toReturn

module.exports = new ComponentManager