package proto

// TypeFluxSpeaker starts and stops the phone as a speaker of this
// computer: fluxd sends the audio of the default output to the phone, and
// the phone plays it. Both sides send it. docs/camera.md describes it.
const TypeFluxSpeaker = "flux.speaker"

func init() {
	Incoming = append(Incoming, TypeFluxSpeaker)
	Outgoing = append(Outgoing, TypeFluxSpeaker)
}
