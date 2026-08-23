import ./errors

type
  Unit* = object

  Result*[T] = object
    case isOk*: bool
    of true:
      value*: T
    of false:
      error*: HostError

proc success*[T](value: sink T): Result[T] =
  Result[T](isOk: true, value: value)

proc success*(): Result[Unit] =
  success(Unit())

proc failure*[T](error: sink HostError): Result[T] =
  Result[T](isOk: false, error: error)
