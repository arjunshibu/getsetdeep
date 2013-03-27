# Import
EventEmitter = require('events').EventEmitter
balUtilFlow = require('./flow')
balUtilTypes = require('./types')


# =====================================
# EventEmitterEnhanced
# Extends the standard EventEmitter with support for:
# - support for emitting events both async and sync

class EventEmitterEnhanced extends EventEmitter

	# Get Listener Group
	# Fetch the listeners for a particular event as a task group
	getListenerGroup: (eventName,data,next) ->
		# Get listeners
		me = @
		listeners = @listeners(eventName)

		# Prepare tasks
		tasks = new balUtilFlow.Group(next)

		# Add the tasks for the listeners
		balUtilFlow.each listeners, (listener) ->
			# Once will actually wrap around the original listener, which isn't what we want for the introspection
			# So we must pass fireWithOptionalCallback an array of the method to fire, and the method to introspect
			# https://github.com/bevry/docpad/issues/462
			# https://github.com/joyent/node/commit/d1b4dcd6acb1d1c66e423f7992dc6eec8a35c544
			listener = [listener,listener.listener]  if listener.listener

			# Bind to the task
			tasks.push (complete) ->
				# Fire the listener, treating the callback as optional
				balUtilFlow.fireWithOptionalCallback(listener,[data,complete],me)

		# Return
		return tasks

	# Emit Serial
	emitSync: (args...) -> @emitSerial(args...)
	emitSerial: (args...) -> @getListenerGroup(args...).run('serial')

	# Emit Parallel
	emitAsync: (args...) -> @emitParallel(args...)
	emitParallel: (args...) -> @getListenerGroup(args...).run('parallel')


# =====================================
# Event & EventSystem
# Extends the EventEmitterEnhanced with support for:
# - blocking events
# - start and finish events

# Event
class Event
	# The name of the event
	name: null
	# Is the event currently locked?
	locked: false
	# Has the event finished running?
	finished: false
	# Apply our name on construction
	constructor: ({@name}) ->

# EventSystem
class EventSystem extends EventEmitterEnhanced
	# Event store
	# initialised in our event function to prevent javascript reference problems
	_eventSystemEvents: null

	# Fetch the event object for the event
	event: (eventName) ->
		# Prepare
		@_eventSystemEvents or= {}
		# Return the fetched event, create it if it doesn't exist already
		@_eventSystemEvents[eventName] or= new Event(eventName)

	# Lock the event
	# next(err)
	lock: (eventName, next) ->
		# Grab the event
		event = @event eventName
		# Grab a lock on the event
		if event.locked is false
			# Place the lock
			event.locked = true
			# Trigger our event
			# then fire our callback
			try
				@emit eventName+':locked'
			catch err
				next(err)
				return @
			finally
				next()
		else
			# Wait until the current task has finished
			@onceUnlocked eventName, (err) =>
				return next(err)  if err
				# Then try again
				@lock eventName, next

		# Chain
		@

	# Unlock the event
	# next(err)
	unlock: (eventName, next) ->
		# Grab the event
		event = @event eventName
		# Release the lock
		event.locked = false
		# Trigger our event
		# then fire our callback
		try
			@emit eventName+':unlocked'
		catch err
			next(err)
			return @
		finally
			next()
		# Chain
		@

	# Start our event
	# 1. Performs a lock
	# 2. Sets event's finished flag to false
	# 3. Fires callback
	# next(err)
	start: (eventName, next) ->
		# Grab a locak
		@lock eventName, (err) =>
			# Error?
			return next(err)  if err
			# Grab the event
			event = @event eventName
			# Set as started
			event.finished = false
			# Trigger our event
			# then fire our callback
			try
				@emit eventName+':started'
			catch err
				next(err)
				return @
			finally
				next()
		# Chain
		@

	# Finish, alias for finished
	finish: (args...) ->
		@finished.apply(@,args)

	# Finished our event
	# 1. Sets event's finished flag to true
	# 2. Unlocks the event
	# 3. Fires callback
	# next(err)
	finished: (eventName, next) ->
		# Grab the event
		event = @event eventName
		# Set as finished
		event.finished = true
		# Unlock
		@unlock eventName, (err) =>
			# Error?
			return next(err)  if err
			# Trigger our event
			# then fire our callback
			try
				@emit eventName+':finished'
			catch err
				next(err)
				return @
			finally
				next()
		# Chain
		@

	# Run one time once an event has unlocked
	# next(err)
	onceUnlocked: (eventName, next) ->
		# Grab the event
		event = @event eventName
		# Check lock status
		if event.locked
			# Wait until our event has unlocked to fire the callback
			@once eventName+':unlocked', next
		else
			# Fire our callback now
			next()
		# Chain
		@

	# Run one time once an event has finished
	# next(err)
	onceFinished: (eventName, next) ->
		# Grab the event
		event = @event eventName
		# Check finish status
		if event.finished
			# Fire our callback now
			next()
		else
			# Wait until our event has finished to fire the callback
			@once eventName+':finished', next
		# Chain
		@

	# Run every time an event has finished
	# next(err)
	whenFinished: (eventName, next) ->
		# Grab the event
		event = @event eventName
		# Check finish status
		if event.finished
			# Fire our callback now
			next()
		# Everytime our even has finished, fire the callback
		@on eventName+':finished', next
		# Chain
		@

	# When, alias for on
	when: (args...) ->
		@on.apply(@,args)

	# Block an event from running
	# next(err)
	block: (eventNames, next) ->
		# Ensure array
		unless balUtilTypes.isArray(eventNames)
			if balUtilTypes.isString(eventNames)
				eventNames = eventNames.split(/[,\s]+/g)
			else
				err = new Error('Unknown eventNames type')
				return next(err)
		total = eventNames.length
		done = 0
		# Block these events
		for eventName in eventNames
			@lock eventName, (err) ->
				# Error?
				if err
					done = total
					return next(err)
				# Increment
				done++
				if done is total
					next()
		# Chain
		@

	# Unblock an event from running
	# next(err)
	unblock: (eventNames, next) ->
		# Ensure array
		unless balUtilTypes.isArray(eventNames)
			if balUtilTypes.isString(eventNames)
				eventNames = eventNames.split /[,\s]+/g
			else
				err = new Error('Unknown eventNames type')
				return next(err)
		total = eventNames.length
		done = 0
		# Block these events
		for eventName in eventNames
			@unlock eventName, (err) ->
				# Error?
				if err
					done = total
					return next(err)
				# Increment
				done++
				if done is total
					next()
		# Chain
		@



# =====================================
# Export

module.exports = {EventEmitterEnhanced,Event,EventSystem}