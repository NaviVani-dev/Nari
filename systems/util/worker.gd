class_name Worker

class Result extends RefCounted:
	signal done(value: Variant)

static var _running: Array[int] = []

static func run(job: Callable) -> Variant:
	var result := Result.new()
	var task := WorkerThreadPool.add_task(func(): result.done.emit.call_deferred(job.call()))
	_running.append(task)
	var value: Variant = await result.done
	if _running.has(task):
		_running.erase(task)
		WorkerThreadPool.wait_for_task_completion(task)
	return value

static func finish() -> void:
	for task in _running:
		WorkerThreadPool.wait_for_task_completion(task)
	_running.clear()
