//go:build windows

package tunnel

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"net"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// initialConfigBytes is a first guess for WireGuardGetConfiguration's buffer;
// it is grown on ERROR_MORE_DATA.
const initialConfigBytes = 0x10000

// Winsock address families used by SOCKADDR_INET.
const (
	afInet  = 2
	afInet6 = 23
)

// FILETIME is a 64-bit count of 100ns intervals since 1601-01-01.
const (
	filetimeUnixEpoch = 116444736000000000
	filetimePerSecond = 10000000
)

// wgInterface mirrors upstream `WIREGUARD_INTERFACE` from wireguard.h. The
// layout is load-bearing: WireGuardGetConfiguration returns one interface
// immediately followed by PeersCount peer structs. The explicit pads keep the
// Go struct at the C size and offsets (DWORD alignment puts PeersCount at 72;
// the ALIGNED(8) C struct rounds the total to 80).
type wgInterface struct {
	Flags      uint32
	ListenPort uint16
	PrivateKey [32]byte
	PublicKey  [32]byte
	PeersCount uint32 // offset 72
	_          [4]byte
}

// wgPeer mirrors upstream `WIREGUARD_PEER`. Field order, sizes and the
// explicit padding must match the C struct (136 bytes; SOCKADDR_INET is
// 4-aligned, placing Endpoint at 76), or reads land on the wrong offsets.
type wgPeer struct {
	Flags               uint32
	Reserved            uint32
	PublicKey           [32]byte
	PresharedKey        [32]byte
	PersistentKeepalive uint16
	_                   [2]byte  // align SOCKADDR_INET to offset 76
	Endpoint            [28]byte // SOCKADDR_INET: sockaddr_in (16) / sockaddr_in6 (28)
	TxBytes             uint64
	RxBytes             uint64
	LastHandshake       uint64 // 100ns intervals since 1601-01-01, or 0
	AllowedIPsCount     uint32
	_                   [4]byte
}

// wireGuardReader reads the live configuration of the tunnel adapter through
// the bundled wireguard.dll. It runs inside the LocalSystem daemon, so it can
// open an adapter created by the tunnel service.
type wireGuardReader struct {
	dllPath func() (string, error)
}

func newWireGuardReader() *wireGuardReader {
	return &wireGuardReader{dllPath: wireguardDLLPath}
}

func wireguardDLLPath() (string, error) {
	dir, err := executableDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "wireguard.dll"), nil
}

func (r *wireGuardReader) read(_ context.Context, iface string) ([]peer, error) {
	dllPath, err := r.dllPath()
	if err != nil {
		return nil, err
	}
	// Absolute path: the loader must never search the CWD or PATH.
	dll, err := syscall.LoadDLL(dllPath)
	if err != nil {
		return nil, err
	}
	defer func() { _ = dll.Release() }()

	open, err := dll.FindProc("WireGuardOpenAdapter")
	if err != nil {
		return nil, err
	}
	closeAdapter, err := dll.FindProc("WireGuardCloseAdapter")
	if err != nil {
		return nil, err
	}
	getConfig, err := dll.FindProc("WireGuardGetConfiguration")
	if err != nil {
		return nil, err
	}

	name, err := syscall.UTF16PtrFromString(iface)
	if err != nil {
		return nil, err
	}
	handle, _, _ := open.Call(uintptr(unsafe.Pointer(name)))
	if handle == 0 {
		return nil, errors.New("open wireguard adapter: unavailable")
	}
	defer func() { _, _, _ = closeAdapter.Call(handle) }()

	return readConfiguration(getConfig, handle)
}

func readConfiguration(getConfig *syscall.Proc, handle uintptr) ([]peer, error) {
	buffer := make([]byte, initialConfigBytes)
	for attempt := 0; attempt < 4; attempt++ {
		size := uint32(len(buffer))
		ret, _, callErr := getConfig.Call(
			handle,
			uintptr(unsafe.Pointer(&buffer[0])),
			uintptr(unsafe.Pointer(&size)),
		)
		if ret != 0 {
			return peersFromConfig(buffer)
		}
		// The driver answers ERROR_MORE_DATA with the required size.
		if !errors.Is(callErr, windows.ERROR_MORE_DATA) {
			return nil, callErr
		}
		buffer = make([]byte, size)
	}
	return nil, errors.New("read wireguard configuration: buffer kept growing")
}

func peersFromConfig(buffer []byte) ([]peer, error) {
	ifaceSize := int(unsafe.Sizeof(wgInterface{}))
	peerSize := int(unsafe.Sizeof(wgPeer{}))
	if len(buffer) < ifaceSize {
		return nil, errors.New("wireguard configuration is short")
	}

	config := (*wgInterface)(unsafe.Pointer(&buffer[0]))
	needed := ifaceSize + int(config.PeersCount)*peerSize
	if len(buffer) < needed {
		return nil, errors.New("wireguard configuration is truncated")
	}

	raw := unsafe.Slice((*wgPeer)(unsafe.Pointer(&buffer[ifaceSize])), config.PeersCount)
	peers := make([]peer, 0, len(raw))
	for i := range raw {
		peers = append(peers, peer{
			publicKey:     encodeKey(raw[i].PublicKey),
			endpoint:      formatEndpoint(raw[i].Endpoint),
			lastHandshake: filetimeToTime(raw[i].LastHandshake),
			rxBytes:       int64(raw[i].RxBytes),
			txBytes:       int64(raw[i].TxBytes),
		})
	}
	return peers, nil
}

// encodeKey renders a raw 32-byte WireGuard key as standard base64, matching
// the Dart client's decoder.
func encodeKey(key [32]byte) string {
	return base64.StdEncoding.EncodeToString(key[:])
}

// formatEndpoint renders a Windows SOCKADDR_INET (as raw bytes) as
// `host:port`, bracketing IPv6 hosts so it matches the Dart client's own
// formatter. An unknown family yields the empty string (treated as unknown).
func formatEndpoint(raw [28]byte) string {
	family := binary.LittleEndian.Uint16(raw[0:2])
	// Ports are stored in network byte order even though the family field is
	// host byte order.
	port := binary.BigEndian.Uint16(raw[2:4])
	switch family {
	case afInet:
		return net.JoinHostPort(net.IP(raw[4:8]).String(), strconv.FormatUint(uint64(port), 10))
	case afInet6:
		return net.JoinHostPort(net.IP(raw[8:24]).String(), strconv.FormatUint(uint64(port), 10))
	default:
		return ""
	}
}

// filetimeToTime converts a Windows FILETIME to a time. Zero (or anything at
// or before the Unix epoch, i.e. "never handshook") stays the zero time so
// callers treat it as unknown rather than a fabricated timestamp.
func filetimeToTime(value uint64) time.Time {
	if value <= filetimeUnixEpoch {
		return time.Time{}
	}
	delta := value - filetimeUnixEpoch
	seconds := int64(delta / filetimePerSecond)
	nanos := int64(delta%filetimePerSecond) * 100
	return time.Unix(seconds, nanos).UTC()
}
