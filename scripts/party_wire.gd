extends RefCounted
## Party messages that travel as raw packets beside the RPCs.
##
## Adding an @rpc method changes the node's RPC table and makes every 0.2.0
## peer log engine errors (tested: docs/specs, section 9, T7), so everything
## added after 0.2.0 goes through here instead: one stable entry point
## (SceneMultiplayer.send_bytes / peer_packet) with its own versioned dispatch.
## A 0.2.0 build has nothing connected to peer_packet and ignores these.
##
## Packet: "GJ", wire version, message kind, then var_to_bytes(Dictionary).
## Decoding never allows objects, and anything malformed decodes to {}.
## A newer wire version is still read: fields are only ever added, and readers
## ignore the ones they do not know.

const MAGIC_0 := 0x47 # G
const MAGIC_1 := 0x4A # J
const VERSION := 1
const MAX_BYTES := 65536

## Both ways after _register: the sender's core build and installed games.
## The host's also carries its file-server port.
const HELLO := 1
## Host to members: the party's playable games, every member's state for the
## current game, and whether a round is on (and who is in it).
const PARTY := 2
## Member to host: where this member is with the current game
## (ready, downloading, needs update, declined, ...).
const STATUS := 3
## Member to host: asks to select a color for one of its seats.
const PICK_COLOR := 4
## Host to the requesting member: explains why a color request failed.
const COLOR_REJECTED := 5
## Leader to host: mark an unoccupied slot as a bot or open.
const SET_BOT := 6

static func encode(kind: int, payload: Dictionary) -> PackedByteArray:
	var bytes := PackedByteArray([MAGIC_0, MAGIC_1, VERSION, kind])
	bytes.append_array(var_to_bytes(payload))
	return bytes

## {"kind": int, "data": Dictionary}, or {} if it is not one of ours.
static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 5 or bytes.size() > MAX_BYTES: return {}
	if bytes[0] != MAGIC_0 or bytes[1] != MAGIC_1 or bytes[2] < 1: return {}
	var data: Variant = bytes_to_var(bytes.slice(4))
	if typeof(data) != TYPE_DICTIONARY: return {}
	return {"kind": int(bytes[3]), "version": int(bytes[2]), "data": data}
