// The stream transport's wire format and client bridge, extracted from
// boltmeshd so the Android native module can carry the identical protocol
// rather than a second implementation that could drift.
//
// The package had to leave `boltmeshd/internal/stream`: Go's internal rule
// makes that package unimportable from another module, and android/awg-native
// is its own module. Both consumers depend on this one through a local
// `replace`, so there is a single implementation and one golden-vector suite.
module boltmesh/stream

go 1.27
