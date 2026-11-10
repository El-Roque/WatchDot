#![deny(unsafe_op_in_unsafe_fn)]

use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::time::{Duration, Instant};
use str0m::change::{SdpAnswer, SdpPendingOffer};
use str0m::channel::ChannelId;
use str0m::format::Codec;
use str0m::media::{Direction, Frequency, MediaKind, MediaTime, Mid};
use str0m::net::{Protocol, Receive, TcpType};
use str0m::{Candidate, Event, IceConnectionState, IceCreds, Input, Output, Rtc};

const CANDIDATE_BUDGET: usize = 100;
const OPUS_RECEIVE_BITRATE: u32 = 24_000;

// RFC 7587: maxaveragebitrate is an independent receive-only limit, not an
// encoder setting or a codec-compatibility parameter. str0m 0.24.1 does not
// expose it in FormatParams, so add it to the serialized local offer only.
// ICE, DTLS, SCTP and every other codec parameter remain unchanged.
fn limited_opus_offer(sdp: &str) -> Result<String, i32> {
    if sdp.len() > 65_536 { return Err(-2); }
    fn audio_section(lines: &[&str], output: &mut Vec<String>) -> Result<usize, i32> {
        if !lines.first().is_some_and(|line| line.starts_with("m=audio ")) {
            output.extend(lines.iter().map(|line| (*line).to_owned()));
            return Ok(0);
        }
        let mut opus = HashSet::new();
        for line in lines {
            if let Some(rest) = line.strip_prefix("a=rtpmap:") {
                if let Some((pt, codec)) = rest.split_once(' ') {
                    if codec.eq_ignore_ascii_case("opus/48000/2") {
                        let value = pt.parse::<u8>().map_err(|_| -2)?;
                        if value > 127 || !opus.insert(pt.to_owned()) { return Err(-2); }
                    }
                }
            }
        }
        let mut fmtp = HashSet::new();
        for line in lines {
            if let Some(rest) = line.strip_prefix("a=fmtp:") {
                let (pt, parameters) = rest.split_once(' ').unwrap_or((rest, ""));
                if opus.contains(pt) {
                    if !fmtp.insert(pt.to_owned()) { return Err(-2); }
                    let mut parts: Vec<String> = parameters.split(';').map(str::trim)
                        .filter(|value| !value.is_empty())
                        .filter(|value| !value.split('=').next().unwrap_or("").trim().eq_ignore_ascii_case("maxaveragebitrate"))
                        .map(str::to_owned).collect();
                    parts.push(format!("maxaveragebitrate={OPUS_RECEIVE_BITRATE}"));
                    output.push(format!("a=fmtp:{pt} {}", parts.join(";")));
                    continue;
                }
            }
            output.push((*line).to_owned());
        }
        for pt in opus.difference(&fmtp) {
            output.push(format!("a=fmtp:{pt} maxaveragebitrate={OPUS_RECEIVE_BITRATE}"));
        }
        Ok(opus.len())
    }
    let mut output = Vec::new();
    let mut section = Vec::new();
    let mut limited = 0;
    for line in sdp.lines() {
        if line.starts_with("m=") && !section.is_empty() {
            limited += audio_section(&section, &mut output)?;
            section.clear();
        }
        section.push(line);
    }
    limited += audio_section(&section, &mut output)?;
    if limited == 0 { return Err(-2); }
    Ok(output.join("\r\n") + "\r\n")
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct OpenClawRTCAddress {
    address: [u8; 16],
    port: u16,
    family: u16,
}

impl OpenClawRTCAddress {
    fn socket(self) -> Result<SocketAddr, i32> {
        let ip = match self.family {
            4 => IpAddr::V4(Ipv4Addr::new(
                self.address[0],
                self.address[1],
                self.address[2],
                self.address[3],
            )),
            6 => IpAddr::V6(Ipv6Addr::from(self.address)),
            _ => return Err(-2),
        };
        if self.port == 0 || ip.is_unspecified() || ip.is_multicast() {
            return Err(-2);
        }
        Ok(SocketAddr::new(ip, self.port))
    }
}

impl From<SocketAddr> for OpenClawRTCAddress {
    fn from(value: SocketAddr) -> Self {
        let mut result = Self {
            port: value.port(),
            ..Self::default()
        };
        match value.ip() {
            IpAddr::V4(ip) => {
                result.family = 4;
                result.address[..4].copy_from_slice(&ip.octets());
            }
            IpAddr::V6(ip) => {
                result.family = 6;
                result.address = ip.octets();
            }
        }
        result
    }
}

#[repr(C)]
#[derive(Default)]
pub struct OpenClawRTCOutput {
    kind: u32,
    bytes: *const u8,
    length: usize,
    source: OpenClawRTCAddress,
    destination: OpenClawRTCAddress,
    time: u64,
}

struct RemoteAddress {
    address: SocketAddr,
    candidates: Vec<Candidate>,
    resolved: Vec<SocketAddr>,
}

#[derive(Default)]
pub struct OpenClawRTC {
    rtc: Option<Rtc>,
    // Retiring a failed engine must leave its description and borrowed buffers owned.
    state: RtcSessionState,
}

#[derive(Default)]
struct RtcSessionState {
    tcp_only: bool,
    pending: Option<SdpPendingOffer>,
    mid: Option<Mid>,
    description: Vec<u8>,
    remote_addresses: Vec<RemoteAddress>,
    output_bytes: Vec<u8>,
    events_channel: Option<ChannelId>,
    events_open: bool,
}

// A panic must not cross the C ABI. A failed engine is discarded, never reused.
unsafe fn operate(
    pointer: *mut OpenClawRTC,
    operation: impl FnOnce(&mut Rtc, &mut RtcSessionState) -> Result<(), i32>,
) -> i32 {
    let Some(owner) = (unsafe { pointer.as_mut() }) else {
        return -1;
    };
    let Some(rtc) = owner.rtc.as_mut() else {
        return -1;
    };
    match catch_unwind(AssertUnwindSafe(|| operation(rtc, &mut owner.state))) {
        Ok(Ok(())) => 0,
        Ok(Err(code)) => code,
        Err(_) => {
            owner.rtc = None;
            -1
        }
    }
}

unsafe fn input<'a>(bytes: *const u8, length: usize, maximum: usize) -> Result<&'a [u8], i32> {
    if bytes.is_null() || length == 0 || length > maximum {
        return Err(-2);
    }
    Ok(unsafe { std::slice::from_raw_parts(bytes, length) })
}

#[unsafe(no_mangle)]
pub extern "C" fn openclaw_rtc_create() -> *mut OpenClawRTC {
    create(false)
}

/// Opt-in independent Watch transport; the original constructor remains UDP.
#[unsafe(no_mangle)]
pub extern "C" fn watchdot_rtc_create_tcp() -> *mut OpenClawRTC {
    create(true)
}

fn create(tcp_only: bool) -> *mut OpenClawRTC {
    catch_unwind(|| {
        // The pinned ICE default uses a non-cryptographic RNG. Supply independent
        // OS entropy: 64 bits for the ufrag and 192 bits for the password.
        let mut entropy = [0_u8; 32];
        if getrandom::fill(&mut entropy).is_err() {
            return ptr::null_mut();
        }
        let credentials = IceCreds {
            ufrag: entropy[..8]
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect(),
            pass: entropy[8..]
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect(),
        };
        let rtc = Rtc::builder()
            .set_local_ice_credentials(credentials)
            .clear_codecs()
            .enable_opus(true, false)
            // Contiguous audio is released immediately. Allow a short window
            // for reordered packets, bounded even when the speaker pauses.
            .set_reordering_size_audio(8)
            .set_reordering_timeout_audio(Some(Duration::from_millis(60)))
            .build(Instant::now());
        Box::into_raw(Box::new(OpenClawRTC {
            rtc: Some(rtc),
            state: RtcSessionState { tcp_only, ..RtcSessionState::default() },
        }))
    })
    .unwrap_or(ptr::null_mut())
}

fn local_candidate(address: SocketAddr, tcp_only: bool) -> Result<Candidate, i32> {
    if tcp_only {
        Candidate::builder().tcp().host(address).tcptype(TcpType::Active).build().map_err(|_| -2)
    } else {
        Candidate::host(address, Protocol::Udp).map_err(|_| -2)
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_free(pointer: *mut OpenClawRTC) {
    if !pointer.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(pointer) })));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_add_candidate(
    pointer: *mut OpenClawRTC,
    address: OpenClawRTCAddress,
) -> i32 {
    unsafe {
        operate(pointer, |rtc, state| {
            let candidate = local_candidate(address.socket()?, state.tcp_only)?;
            rtc.add_local_candidate(candidate);
            Ok(())
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_offer(pointer: *mut OpenClawRTC) -> i32 {
    unsafe {
        operate(pointer, |rtc, state| {
            if state.pending.is_some() || state.mid.is_some() {
                return Err(-1);
            }
            let mut changes = rtc.sdp_api();
            state.mid =
                Some(changes.add_media(MediaKind::Audio, Direction::SendRecv, None, None, None));
            state.events_channel = Some(changes.add_channel("oai-events".into()));
            let (offer, pending) = changes.apply().ok_or(-1)?;
            state.pending = Some(pending);
            state.description = limited_opus_offer(&offer.to_sdp_string())?.into_bytes();
            Ok(())
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_remove_candidate(
    pointer: *mut OpenClawRTC,
    address: OpenClawRTCAddress,
) -> i32 {
    unsafe {
        operate(pointer, |rtc, state| {
            let candidate = local_candidate(address.socket()?, state.tcp_only)?;
            // Only retire ICE state after our one SDP exchange; no later SDP offer
            // is generated from direct-API mutations.
            rtc.direct_api().invalidate_candidate(&candidate);
            Ok(())
        })
    }
}

// Discovery metadata only: the unchanged SDP/ICE owner decides which candidates form pairs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_remote_address(
    pointer: *const OpenClawRTC,
    index: usize,
    address: *mut OpenClawRTCAddress,
) -> i32 {
    let (Some(owner), Some(address)) = (unsafe { pointer.as_ref() }, unsafe { address.as_mut() })
    else {
        return -1;
    };
    if owner.rtc.is_none() {
        return -1;
    }
    let Some(value) = owner.state.remote_addresses.get(index) else {
        return 1;
    };
    *address = value.address.into();
    0
}

fn resolved_candidate(candidate: &Candidate, address: SocketAddr) -> Result<Candidate, i32> {
    // The pinned API has no address setter. Its canonical candidate attribute
    // preserves component, priority, protocol, TCP role and ufrag; constructing a host instead
    // would bypass the ICE owner's admission rules. Never rewrite the full SDP.
    let text = candidate.to_sdp_string();
    let mut fields: Vec<_> = text.split_ascii_whitespace().collect();
    let ip = address.ip().to_string();
    let port = address.port().to_string();
    fields[4] = &ip;
    fields[5] = &port;
    Candidate::from_sdp_string(&fields.join(" ")).map_err(|_| -2)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_resolve_remote_address(
    pointer: *mut OpenClawRTC,
    index: usize,
    address: OpenClawRTCAddress,
) -> i32 {
    unsafe {
        operate(pointer, |rtc, state| {
            let address = address.socket()?;
            let remote = state.remote_addresses.get(index).ok_or(-2)?;
            // UDP accepts only its existing DNS64 mapping. In independent TCP
            // mode the caller may report the actual peer of an established
            // system-proxied connection, including a translated port/family.
            // Keep the negotiated ICE attributes and DTLS fingerprint intact.
            if !state.tcp_only && (!remote.address.is_ipv4()
                || !address.is_ipv6()
                || remote.address.port() != address.port()) {
                return Err(-2);
            }
            if state.tcp_only && address == remote.address { return Ok(()); }
            if remote.resolved.contains(&address) {
                return Ok(());
            }
            let endpoints: HashSet<_> = state
                .remote_addresses
                .iter()
                .flat_map(|remote| {
                    std::iter::once(remote.address).chain(remote.resolved.iter().copied())
                })
                .collect();
            if endpoints.len() >= CANDIDATE_BUDGET && !endpoints.contains(&address) {
                return Err(-4);
            }
            let candidates = remote
                .candidates
                .iter()
                .map(|candidate| resolved_candidate(candidate, address))
                .collect::<Result<Vec<_>, _>>()?;
            for candidate in candidates {
                rtc.add_remote_candidate(candidate);
            }
            state.remote_addresses[index].resolved.push(address);
            Ok(())
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_description(
    pointer: *const OpenClawRTC,
    length: *mut usize,
) -> *const u8 {
    let (Some(owner), Some(length)) = (unsafe { pointer.as_ref() }, unsafe { length.as_mut() })
    else {
        return ptr::null();
    };
    *length = owner.state.description.len();
    owner.state.description.as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_answer(
    pointer: *mut OpenClawRTC,
    bytes: *const u8,
    length: usize,
) -> i32 {
    unsafe {
        operate(pointer, |rtc, state| {
            let text = std::str::from_utf8(input(bytes, length, 65_536)?).map_err(|_| -2)?;
            let answer = SdpAnswer::from_sdp_string(text).map_err(|_| -2)?;
            // RFC 8838 Appendix B permits discovering our candidates through checks only
            // for an ICE-lite peer. This single-exchange client has no trickle channel.
            if !answer.session.ice_lite() {
                return Err(-3);
            }
            let credentials = answer
                .session
                .ice_creds()
                .or_else(|| {
                    answer
                        .media_lines
                        .iter()
                        .find_map(|media| media.ice_creds())
                })
                .ok_or(-2)?;
            let mut remote_addresses: Vec<RemoteAddress> = Vec::new();
            for candidate in answer.session.ice_candidates().chain(
                answer
                    .media_lines
                    .iter()
                    .flat_map(|media| media.ice_candidates()),
            ) {
                let supported = if state.tcp_only {
                    candidate.proto() == Protocol::Tcp && candidate.tcptype() == Some(TcpType::Passive)
                } else {
                    candidate.proto() == Protocol::Udp
                };
                if !supported
                    || candidate
                        .ufrag()
                        .is_some_and(|value| value != credentials.ufrag.as_str())
                {
                    continue;
                }
                let address = candidate.addr();
                OpenClawRTCAddress::from(address).socket()?;
                if let Some(remote) = remote_addresses
                    .iter_mut()
                    .find(|remote| remote.address == address)
                {
                    if !remote.candidates.contains(candidate) {
                        remote.candidates.push(candidate.clone());
                    }
                } else {
                    remote_addresses.push(RemoteAddress {
                        address,
                        candidates: vec![candidate.clone()],
                        resolved: Vec::new(),
                    });
                }
            }
            if remote_addresses.is_empty() {
                return Err(-3);
            }
            // Match the pinned ICE owner's default pair budget; never truncate the answer.
            if remote_addresses.len() > CANDIDATE_BUDGET {
                return Err(-4);
            }
            let pending = state.pending.take().ok_or(-1)?;
            rtc.sdp_api()
                .accept_answer(pending, answer)
                .map_err(|_| -1)?;
            state.remote_addresses = remote_addresses;
            Ok(())
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_receive(
    pointer: *mut OpenClawRTC,
    source: OpenClawRTCAddress,
    destination: OpenClawRTCAddress,
    bytes: *const u8,
    length: usize,
) -> i32 {
    unsafe {
        operate(pointer, |rtc, state| {
            let bytes = input(bytes, length, 2_000)?;
            let Ok(receive) = Receive::new(
                if state.tcp_only { Protocol::Tcp } else { Protocol::Udp },
                source.socket()?,
                destination.socket()?,
                bytes,
            ) else {
                return Ok(()); // Unrelated/invalid UDP is not a session failure.
            };
            let input = Input::Receive(Instant::now(), receive);
            if rtc.accepts(&input) {
                rtc.handle_input(input).map_err(|_| -1)?;
            }
            Ok(())
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_send_opus(
    pointer: *mut OpenClawRTC,
    bytes: *const u8,
    length: usize,
    timestamp: u64,
) -> i32 {
    unsafe {
        operate(pointer, |rtc, state| {
            let bytes = input(bytes, length, 1_275)?;
            if !rtc.is_connected() {
                return Ok(());
            }
            let writer = rtc.writer(state.mid.ok_or(-1)?).ok_or(-1)?;
            let pt = writer
                .payload_params()
                .find(|p| p.spec().codec == Codec::Opus)
                .ok_or(-1)?
                .pt();
            writer
                .write(
                    pt,
                    Instant::now(),
                    MediaTime::new(timestamp, Frequency::FORTY_EIGHT_KHZ),
                    bytes,
                )
                .map_err(|_| -1)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_timeout(pointer: *mut OpenClawRTC) -> i32 {
    unsafe {
        operate(pointer, |rtc, _| {
            rtc.handle_input(Input::Timeout(Instant::now()))
                .map_err(|_| -1)
        })
    }
}

/// Send one bounded UTF-8 text message on the reliable, ordered oai-events channel.
/// -5 means not open, -6 means backpressure; the caller retains and retries its bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn watchdot_rtc_send_event(
    pointer: *mut OpenClawRTC,
    bytes: *const u8,
    length: usize,
) -> i32 {
    unsafe {
        operate(pointer, |rtc, state| {
            let bytes = input(bytes, length, 65_536)?;
            std::str::from_utf8(bytes).map_err(|_| -2)?;
            if !state.events_open { return Err(-5); }
            let id = state.events_channel.ok_or(-5)?;
            let mut channel = rtc.channel(id).ok_or(-5)?;
            if channel.buffered_amount().saturating_add(bytes.len()) > 262_144 {
                return Err(-6);
            }
            match channel.write(false, bytes).map_err(|_| -1)? {
                true => Ok(()),
                false => Err(-6),
            }
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn openclaw_rtc_poll(
    pointer: *mut OpenClawRTC,
    output: *mut OpenClawRTCOutput,
) -> i32 {
    let Some(output) = (unsafe { output.as_mut() }) else {
        return -2;
    };
    unsafe {
        operate(pointer, |rtc, state| {
            *output = OpenClawRTCOutput::default();
            loop {
                match rtc.poll_output().map_err(|_| -1)? {
                    Output::Timeout(deadline) => {
                        output.time = deadline
                            .saturating_duration_since(Instant::now())
                            .as_millis()
                            .min(60_000) as u64;
                        return Ok(());
                    }
                    Output::Transmit(packet) => {
                        output.kind = match packet.proto {
                            Protocol::Udp => 1,
                            Protocol::Tcp => 10,
                            _ => return Err(-3),
                        };
                        output.source = packet.source.into();
                        output.destination = packet.destination.into();
                        state.output_bytes.clear();
                        state.output_bytes.extend_from_slice(&packet.contents);
                    }
                    Output::Event(Event::Connected) => output.kind = 2,
                    Output::Event(Event::ChannelOpen(id, label))
                        if Some(id) == state.events_channel && label == "oai-events" =>
                    {
                        state.events_open = true;
                        output.kind = 6;
                    }
                    Output::Event(Event::ChannelData(data))
                        if Some(data.id) == state.events_channel =>
                    {
                        if data.data.len() > 65_536 { return Err(-2); }
                        output.kind = if data.binary { 9 } else { 7 };
                        state.output_bytes = data.data;
                    }
                    Output::Event(Event::ChannelClose(id))
                        if Some(id) == state.events_channel =>
                    {
                        state.events_open = false;
                        output.kind = 8;
                    }
                    Output::Event(Event::MediaData(media))
                        if media.params.spec().codec == Codec::Opus =>
                    {
                        output.kind = 3;
                        output.time = media.time.rebase(Frequency::FORTY_EIGHT_KHZ).numer();
                        state.output_bytes.clear();
                        state.output_bytes.extend_from_slice(&media.data);
                    }
                    Output::Event(Event::IceConnectionStateChange(
                        IceConnectionState::Disconnected,
                    )) => output.kind = 4,
                    Output::Event(Event::Closed) => output.kind = 5,
                    _ => continue,
                }
                if matches!(output.kind, 1 | 3 | 7 | 9 | 10) {
                    output.bytes = state.output_bytes.as_ptr();
                    output.length = state.output_bytes.len();
                }
                return Ok(());
            }
        })
    }
}

#[cfg(test)]
mod tests;

