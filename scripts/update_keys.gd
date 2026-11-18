extends RefCounted
## Public keys trusted to sign update manifests, by key id.
##
## The matching private key never enters the repository: it lives at
## ~/.config/gizmojam/release-signing.key on the release machine. The key id is
## "gizmojam-" plus the first 16 hex digits of the SHA-256 of the DER public key,
## which tools/release.py recomputes from the private key before it signs.
##
## Rotation: a manifest signed by a trusted key may announce `next_key`; the game
## then trusts that key too (see Updater). Ship new builds with both keys listed
## here until every supported build has seen the announcement.

const KEYS := {
	"gizmojam-e66eee89ecb223d4": """-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAl2AEqhTX8VBfUwA43xtU
neR79jDzirpKAWJ1fNEy9nDHk5E5BWUSifW6VriMUtjk70rhiAvdRNpiu2z2Nmpu
yuUzqd8w/0xTt5ckKBN82KWM58WZk/qtqFUsFiGEeECP+rPB4Kq1t+Ub9lHa3mAs
yRZOOzR/gvoi2SYH9mgnhQmhcf/mFxc6VIOi8HbMCIJoiI/r+4A6MAJwax5IdW1N
N7jEnRagu8NlN5MVYff9Xrr6ayzKJrIPU7Ct/ypZm5nV7rshydHhgiEf73H6CcH+
AYM0bOo+qI4g+Pi8N0mDrp3bamWGM87Zx5M0P2hkih6WAgJmhH0Vng8IIwZW84Cj
ks7bf/MVVF33IWSftlCzlNFUI2A4Qi96sm0HEKgwSgB9y121H2aoWszNdsGvZrhn
XiLSKYIAQFd2CPJDZFx0yqvmNWo65ieg0vzwfB+s7KO7/Wgk/A8clT6vYwuHg6Vo
kwpeSDNN4q9MCyahzgyqfSTp8Zx1Y+rhhuwMeukYsRh7AgMBAAE=
-----END PUBLIC KEY-----
""",
}
