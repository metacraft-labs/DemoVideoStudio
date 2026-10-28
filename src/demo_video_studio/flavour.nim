## A flavour (DemoVideoStudio-Editor §5.1): one concrete way of showing a
## scenario — a backend, reached out of process through its JSON-lines host
## (decision D7), with its configuration.

type
  Flavour* = object
    name*: string
    command*: string
    args*: seq[string]
    virtualTiming*: bool    ## timing applied at render (a terminal flavour, §4.2)
