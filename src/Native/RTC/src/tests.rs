use super::*;
use std::collections::VecDeque;
use std::time::Duration;
use str0m::change::SdpOffer;

const OPUS_SILENCE: &[u8] = &[0xf8, 0xff, 0xfe];
const SYNTHETIC_EVENT: &[u8] = br#"{"type":"watchdot.synthetic.probe","sequence":1}"#;

struct Client(*mut OpenClawRTC);

impl Drop for Client {
    fn drop(&mut self) {
        unsafe { openclaw_rtc_free(self.0) }
    }
}

struct Packet {
    from_client: bool,
    source: SocketAddr,
    destination: SocketAddr,
    bytes: Vec<u8>,
}

#[derive(Default, Debug)]
struct Facts {
    connected: usize,
    peer_connected: usize,
    peer_media: usize,
    client_media: usize,
    client_times: Vec<u64>,
    checks: usize,
    dtls: usize,
    srtp: usize,
    mapped_v4: usize,
    mismatched_media: usize,
    events_open: usize,
    peer_events: usize,
    client_events: Vec<Vec<u8>>,
}

#[derive(Clone, Copy)]
enum Scenario {
    Tcp,
    TcpProxy,
    TcpProxyWrongSource,
    V4,
    V6,
    Nat64,
    WrongSource,
    Component2,
    WrongUfrag,
    LostAudio,
    LateAudio,
    Events,
}

struct Fixture {
    client: Client,
    peer: Rtc,
    packets: VecDeque<Packet>,
    facts: Facts,
    answer_result: i32,
}

impl Fixture {
    fn new(addresses: &[SocketAddr], scenario: Scenario) -> Self {
        let client = Client(if matches!(scenario, Scenario::Tcp | Scenario::TcpProxy | Scenario::TcpProxyWrongSource) { watchdot_rtc_create_tcp() } else { openclaw_rtc_create() });
        assert!(!client.0.is_null());
        let peer = Rtc::builder()
            .clear_codecs()
            .enable_opus(true, false)
            .set_ice_lite(true)
            .build(Instant::now());
        let mut fixture = Self {
            client,
            peer,
            packets: VecDeque::new(),
            facts: Facts::default(),
            answer_result: 0,
        };
        fixture.poll_client();
        assert_eq!(unsafe { openclaw_rtc_offer(fixture.client.0) }, 0);
        fixture.poll_client();
        let mut length = 0;
        let bytes = unsafe { openclaw_rtc_description(fixture.client.0, &mut length) };
        assert!(!bytes.is_null());
        let text = String::from_utf8(unsafe { std::slice::from_raw_parts(bytes, length).to_vec() })
            .unwrap();
        let offer = SdpOffer::from_sdp_string(&text).unwrap();
        assert!(text.contains("m=application "), "SCTP media must be negotiated");
        assert!(text.contains("webrtc-datachannel"));
        assert_eq!(
            offer.session.ice_candidates().count()
                + offer
                    .media_lines
                    .iter()
                    .map(|media| media.ice_candidates().count())
                    .sum::<usize>(),
            0
        );
        fixture.poll_peer();
        for address in addresses {
            fixture
                .peer
                .add_local_candidate(if matches!(scenario, Scenario::Tcp | Scenario::TcpProxy | Scenario::TcpProxyWrongSource) {
                    Candidate::builder().tcp().host(*address).tcptype(TcpType::Passive).build().unwrap()
                } else { Candidate::host(*address, Protocol::Udp).unwrap() });
            fixture.poll_peer();
        }
        let answer = fixture.peer.sdp_api().accept_offer(offer).unwrap();
        assert!(answer.session.ice_lite());
        let mut text = answer.to_sdp_string();
        fixture.poll_peer();
        if matches!(scenario, Scenario::Component2 | Scenario::WrongUfrag) {
            text = text
                .lines()
                .map(|line| {
                    if !line.starts_with("a=candidate:") {
                        return line.to_string();
                    }
                    let mut fields: Vec<_> = line.split_whitespace().map(str::to_owned).collect();
                    if matches!(scenario, Scenario::Component2) {
                        fields[1] = "2".into();
                    } else {
                        fields.extend(["ufrag".into(), "not-the-negotiated-ufrag".into()]);
                    }
                    fields.join(" ")
                })
                .collect::<Vec<_>>()
                .join("\r\n")
                + "\r\n";
        }
        fixture.answer_result =
            unsafe { openclaw_rtc_answer(fixture.client.0, text.as_ptr(), text.len()) };
        fixture.poll_client();
        fixture
    }

    fn poll_client(&mut self) {
        loop {
            let mut output = OpenClawRTCOutput::default();
            assert_eq!(unsafe { openclaw_rtc_poll(self.client.0, &mut output) }, 0);
            // Copy the borrowed payload before the next C call, matching the Swift owner.
            let bytes = if output.length == 0 {
                Vec::new()
            } else {
                assert!(!output.bytes.is_null());
                unsafe { std::slice::from_raw_parts(output.bytes, output.length).to_vec() }
            };
            match output.kind {
                0 => return,
                1 | 10 => self.packets.push_back(Packet {
                    from_client: true,
                    source: output.source.socket().unwrap(),
                    destination: output.destination.socket().unwrap(),
                    bytes,
                }),
                2 => self.facts.connected += 1,
                3 => {
                    assert_eq!(bytes, OPUS_SILENCE);
                    self.facts.client_media += 1;
                    self.facts.client_times.push(output.time);
                }
                6 => self.facts.events_open += 1,
                7 => self.facts.client_events.push(bytes),
                kind => panic!("unexpected terminal C output {kind}: {:?}", self.facts),
            }
        }
    }

    fn poll_peer(&mut self) {
        loop {
            match self.peer.poll_output().unwrap() {
                Output::Timeout(_) => return,
                Output::Transmit(packet) => self.packets.push_back(Packet {
                    from_client: false,
                    source: packet.source,
                    destination: packet.destination,
                    bytes: packet.contents.to_vec(),
                }),
                Output::Event(Event::Connected) => self.facts.peer_connected += 1,
                Output::Event(Event::MediaData(media)) => {
                    assert_eq!(media.params.spec().codec, Codec::Opus);
                    assert_eq!(&media.data[..], OPUS_SILENCE);
                    self.facts.peer_media += 1;
                    let writer = self.peer.writer(media.mid).unwrap();
                    let pt = writer
                        .payload_params()
                        .find(|p| p.spec().codec == Codec::Opus)
                        .unwrap()
                        .pt();
                    writer
                        .write(pt, Instant::now(), media.time, media.data)
                        .unwrap();
                }
                Output::Event(Event::ChannelOpen(_, label)) => {
                    assert_eq!(label, "oai-events");
                }
                Output::Event(Event::ChannelData(data)) => {
                    assert!(!data.binary);
                    assert_eq!(data.data.as_slice(), SYNTHETIC_EVENT);
                    self.facts.peer_events += 1;
                    assert!(self.peer.channel(data.id).unwrap().write(false, &data.data).unwrap());
                }
                Output::Event(_) => {}
            }
        }
    }

    fn resolve(&mut self, index: usize, address: SocketAddr) -> i32 {
        let result =
            unsafe { openclaw_rtc_resolve_remote_address(self.client.0, index, address.into()) };
        self.poll_client();
        result
    }

    fn inventory(&self) -> Vec<SocketAddr> {
        let mut result = Vec::new();
        for index in 0..=100 {
            let mut address = OpenClawRTCAddress::default();
            let code = unsafe { openclaw_rtc_remote_address(self.client.0, index, &mut address) };
            if code == 1 {
                return result;
            }
            assert_eq!(code, 0);
            result.push(address.socket().unwrap());
        }
        panic!("unbounded original inventory")
    }
}

fn is_stun(bytes: &[u8]) -> bool {
    bytes.len() >= 20 && bytes[0] & 0xc0 == 0 && bytes[4..8] == [0x21, 0x12, 0xa4, 0x42]
}

fn is_rtp(bytes: &[u8]) -> bool {
    bytes.len() >= 12 && bytes[0] >> 6 == 2 && !(192..=223).contains(&bytes[1])
}

fn has_ipv4_mapping(bytes: &[u8], expected: SocketAddr) -> bool {
    if !is_stun(bytes) || bytes[..2] != [1, 1] {
        return false;
    }
    let mut offset = 20;
    while offset + 4 <= bytes.len() {
        let kind = u16::from_be_bytes([bytes[offset], bytes[offset + 1]]);
        let length = u16::from_be_bytes([bytes[offset + 2], bytes[offset + 3]]) as usize;
        offset += 4;
        if offset + length > bytes.len() {
            return false;
        }
        if kind == 0x20 && length == 8 && bytes[offset + 1] == 1 {
            let port = u16::from_be_bytes([bytes[offset + 2], bytes[offset + 3]]) ^ 0x2112;
            let ip = Ipv4Addr::new(
                bytes[offset + 4] ^ 0x21,
                bytes[offset + 5] ^ 0x12,
                bytes[offset + 6] ^ 0xa4,
                bytes[offset + 7] ^ 0x42,
            );
            return SocketAddr::new(ip.into(), port) == expected;
        }
        offset += (length + 3) & !3;
    }
    false
}

fn prove_media(scenario: Scenario) {
    let nat64 = matches!(
        scenario,
        Scenario::Nat64 | Scenario::Component2 | Scenario::WrongUfrag
    );
    let tcp_proxy = matches!(scenario, Scenario::TcpProxy | Scenario::TcpProxyWrongSource);
    let client: SocketAddr = if nat64 || tcp_proxy || matches!(scenario, Scenario::V6) {
        "[2001:db8:1::10]:40000"
    } else {
        "192.0.2.10:40000"
    }
    .parse()
    .unwrap();
    let peer: SocketAddr = if matches!(scenario, Scenario::V6) {
        "[2001:db8:2::20]:50000"
    } else {
        "198.51.100.20:50000"
    }
    .parse()
    .unwrap();
    // Documentation addresses model translation envelopes only; no OS sockets are opened.
    let resolved = if tcp_proxy {
        "[2001:db8:3::20]:51000".parse().unwrap()
    } else if nat64 {
        "[2001:db8:64::c633:6414]:50000".parse().unwrap()
    } else {
        peer
    };
    let external = if nat64 || tcp_proxy {
        "203.0.113.10:41000".parse().unwrap()
    } else {
        client
    };
    let mut fixture = Fixture::new(&[peer], scenario);
    if matches!(scenario, Scenario::WrongUfrag) {
        assert_eq!(fixture.answer_result, -3);
        assert!(fixture.packets.is_empty());
        return;
    }
    assert_eq!(fixture.answer_result, 0);
    if nat64 || tcp_proxy {
        assert_eq!(fixture.resolve(0, resolved), 0);
    }
    assert_eq!(
        unsafe { openclaw_rtc_add_candidate(fixture.client.0, client.into()) },
        0
    );
    fixture.poll_client();
    let deadline = Instant::now() + Duration::from_millis(1500);
    let mut sent = 0;
    let mut next_media = Instant::now();
    let audio_gap = matches!(scenario, Scenario::LostAudio | Scenario::LateAudio);
    let mut peer_audio = 0;
    let mut delayed_audio = None;
    let mut sent_event = false;
    while Instant::now() < deadline {
        let mut work = 0;
        while let Some(packet) = fixture.packets.pop_front() {
            work += 1;
            assert!(work < 10000, "packet-loop bound");
            if packet.from_client {
                assert_eq!((packet.source, packet.destination), (client, resolved));
                if is_stun(&packet.bytes) {
                    fixture.facts.checks += 1;
                } else if is_rtp(&packet.bytes) {
                    fixture.facts.srtp += 1;
                } else if (20..=63).contains(&packet.bytes[0]) {
                    fixture.facts.dtls += 1;
                }
                let input = Input::Receive(
                    Instant::now(),
                    Receive::new(if matches!(scenario, Scenario::Tcp | Scenario::TcpProxy | Scenario::TcpProxyWrongSource) { Protocol::Tcp } else { Protocol::Udp }, external, peer, &packet.bytes).unwrap(),
                );
                if fixture.peer.accepts(&input) {
                    fixture.peer.handle_input(input).unwrap();
                }
                fixture.poll_peer();
            } else {
                assert_eq!((packet.source, packet.destination), (peer, external));
                if audio_gap && is_rtp(&packet.bytes) {
                    peer_audio += 1;
                    if peer_audio == 2 {
                        if matches!(scenario, Scenario::LateAudio) {
                            delayed_audio = Some(packet);
                        }
                        continue;
                    }
                    if peer_audio == 3 {
                        if let Some(delayed) = delayed_audio.take() {
                            fixture.packets.push_back(delayed);
                        }
                    }
                }
                if (nat64 || tcp_proxy) && has_ipv4_mapping(&packet.bytes, external) {
                    fixture.facts.mapped_v4 += 1;
                }
                let mut source = resolved;
                if matches!(scenario, Scenario::WrongSource | Scenario::TcpProxyWrongSource) && is_rtp(&packet.bytes) {
                    source.set_port(source.port() + 1);
                    fixture.facts.mismatched_media += 1;
                }
                assert_eq!(
                    unsafe {
                        openclaw_rtc_receive(
                            fixture.client.0,
                            source.into(),
                            client.into(),
                            packet.bytes.as_ptr(),
                            packet.bytes.len(),
                        )
                    },
                    0
                );
                fixture.poll_client();
            }
        }
        if matches!(scenario, Scenario::Events | Scenario::Tcp | Scenario::TcpProxy | Scenario::TcpProxyWrongSource) && fixture.facts.events_open > 0 && !sent_event {
            assert_eq!(unsafe {
                watchdot_rtc_send_event(fixture.client.0, SYNTHETIC_EVENT.as_ptr(), SYNTHETIC_EVENT.len())
            }, 0);
            fixture.poll_client();
            sent_event = true;
        }
        if fixture.facts.connected > 0
            && fixture.facts.peer_connected > 0
            && sent < if audio_gap { 3 } else { 12 }
            && Instant::now() >= next_media
        {
            assert_eq!(
                unsafe {
                    openclaw_rtc_send_opus(
                        fixture.client.0,
                        OPUS_SILENCE.as_ptr(),
                        OPUS_SILENCE.len(),
                        (sent + 1) * 960,
                    )
                },
                0
            );
            fixture.poll_client();
            sent += 1;
            next_media = Instant::now() + Duration::from_millis(20);
        }
        if (fixture.facts.client_media >= (if matches!(scenario, Scenario::LostAudio) { 2 } else { 3 })
            && (!matches!(scenario, Scenario::Events | Scenario::Tcp | Scenario::TcpProxy | Scenario::TcpProxyWrongSource) || !fixture.facts.client_events.is_empty()))
            || (matches!(scenario, Scenario::WrongSource | Scenario::TcpProxyWrongSource) && fixture.facts.mismatched_media >= 3)
        {
            break;
        }
        assert_eq!(unsafe { openclaw_rtc_timeout(fixture.client.0) }, 0);
        fixture.poll_client();
        fixture
            .peer
            .handle_input(Input::Timeout(Instant::now()))
            .unwrap();
        fixture.poll_peer();
        std::thread::sleep(Duration::from_millis(1));
    }
    let facts = &fixture.facts;
    if matches!(scenario, Scenario::Events | Scenario::Tcp | Scenario::TcpProxy | Scenario::TcpProxyWrongSource) {
        assert!(sent_event);
        assert_eq!(facts.events_open, 1, "{facts:?}");
        assert_eq!(facts.peer_events, 1, "{facts:?}");
        assert_eq!(facts.client_events, [SYNTHETIC_EVENT.to_vec()], "{facts:?}");
    }
    if matches!(scenario, Scenario::Component2) {
        assert_eq!(facts.connected, 0);
        assert_eq!(facts.checks, 0);
        return;
    }
    assert!(facts.connected > 0 && facts.peer_connected > 0, "{facts:?}");
    assert!(
        facts.checks > 0 && facts.dtls > 0 && facts.srtp > 0,
        "{facts:?}"
    );
    assert!(facts.peer_media >= 3, "{facts:?}");
    if audio_gap {
        // No later speech is sent to flush a reorder buffer after the gap.
        assert_eq!(sent, 3);
        if matches!(scenario, Scenario::LateAudio) {
            assert_eq!(facts.client_times, [960, 1920, 2880], "{facts:?}");
        } else {
            assert_eq!(facts.client_times, [960, 2880], "{facts:?}");
        }
        return;
    }
    if matches!(scenario, Scenario::WrongSource | Scenario::TcpProxyWrongSource) {
        assert!(facts.mismatched_media >= 3);
        assert_eq!(facts.client_media, 0);
    } else {
        assert!(facts.client_media >= 3, "{facts:?}");
    }
    if matches!(scenario, Scenario::Nat64 | Scenario::TcpProxy) {
        assert!(facts.mapped_v4 > 0, "{facts:?}");
    }
}

#[test]
fn direct_ipv4_media() {
    prove_media(Scenario::V4);
}
#[test]
fn tcp_active_to_passive_ice_dtls_srtp_sctp_roundtrip() {
    prove_media(Scenario::Tcp);
}
#[test]
fn tcp_system_proxy_with_changed_family_and_port_keeps_ice_dtls_srtp_sctp() {
    prove_media(Scenario::TcpProxy);
}
#[test]
fn tcp_proxy_media_from_a_different_observed_peer_is_rejected() {
    prove_media(Scenario::TcpProxyWrongSource);
}
#[test]
fn tcp_observed_route_retains_negotiated_ice_attributes_and_identity() {
    let original = "198.51.100.20:50000".parse().unwrap();
    let observed = "[2001:db8:3::20]:51000".parse().unwrap();
    let mut fixture = Fixture::new(&[original], Scenario::Tcp);
    assert_eq!(fixture.answer_result, 0);
    let before = unsafe { &*fixture.client.0 }.state.remote_addresses[0].candidates[0].clone();
    let description = unsafe { &*fixture.client.0 }.state.description.clone();
    assert_eq!(fixture.resolve(0, observed), 0);
    assert_eq!(fixture.resolve(0, observed), 0);
    let after = resolved_candidate(&before, observed).unwrap();
    let before_fields: Vec<_> = before.to_sdp_string().split_whitespace().map(str::to_owned).collect();
    let after_fields: Vec<_> = after.to_sdp_string().split_whitespace().map(str::to_owned).collect();
    assert_eq!(before_fields.len(), after_fields.len());
    for i in 0..before_fields.len() {
        if i != 4 && i != 5 { assert_eq!(before_fields[i], after_fields[i]); }
    }
    assert_eq!(after.addr(), observed);
    assert_eq!(after.proto(), Protocol::Tcp);
    assert_eq!(after.tcptype(), Some(TcpType::Passive));
    assert_eq!(unsafe { &*fixture.client.0 }.state.description, description);
    assert_eq!(fixture.inventory(), vec![original]);
    assert_eq!(unsafe { &*fixture.client.0 }.state.remote_addresses[0].resolved, vec![observed]);
    assert_eq!(fixture.resolve(usize::MAX, observed), -2);
}
#[test]
fn tcp_observed_routes_keep_the_shared_candidate_budget() {
    let original = "198.51.100.20:50000".parse().unwrap();
    let mut fixture = Fixture::new(&[original], Scenario::Tcp);
    for index in 1..=99 { assert_eq!(fixture.resolve(0, alias(index)), 0); }
    assert_eq!(fixture.resolve(0, alias(100)), -4);
    assert_eq!(fixture.resolve(0, alias(1)), 0);
}
#[test]
fn oai_events_roundtrip_over_real_ice_dtls_sctp_without_sockets() {
    prove_media(Scenario::Events);
}

#[test]
fn event_send_rejects_not_open_invalid_utf8_and_oversized() {
    let client = Client(openclaw_rtc_create());
    assert!(!client.0.is_null());
    let mut out = OpenClawRTCOutput::default();
    assert_eq!(unsafe { openclaw_rtc_poll(client.0, &mut out) }, 0);
    assert_eq!(unsafe { watchdot_rtc_send_event(client.0, b"{}".as_ptr(), 2) }, -5);
    assert_eq!(unsafe { watchdot_rtc_send_event(client.0, [0xff].as_ptr(), 1) }, -2);
    let oversized = vec![b'a'; 65_537];
    assert_eq!(unsafe { watchdot_rtc_send_event(client.0, oversized.as_ptr(), oversized.len()) }, -2);
}
#[test]
fn direct_ipv6_media() {
    prove_media(Scenario::V6);
}
#[test]
fn nat64_media_retains_ipv6_route_with_ipv4_mapped_address() {
    prove_media(Scenario::Nat64);
}
#[test]
fn media_from_wrong_source_is_rejected() {
    prove_media(Scenario::WrongSource);
}
#[test]
fn resolved_candidate_does_not_promote_rtcp_component() {
    prove_media(Scenario::Component2);
}
#[test]
fn wrong_ufrag_is_rejected() {
    prove_media(Scenario::WrongUfrag);
}

#[test]
fn lost_audio_followed_by_pause_does_not_hold_received_speech() {
    prove_media(Scenario::LostAudio);
}

#[test]
fn reordered_audio_is_recovered_before_newer_speech_with_bounded_wait() {
    prove_media(Scenario::LateAudio);
}

fn alias(index: u16) -> SocketAddr {
    format!("[2001:db8:64::{index:x}]:50000").parse().unwrap()
}

#[test]
fn invalid_resolution_inputs_leave_owner_usable() {
    let original = "198.51.100.20:50000".parse().unwrap();
    let mut fixture = Fixture::new(&[original], Scenario::V4);
    assert_eq!(fixture.answer_result, 0);
    for (index, address) in [
        (usize::MAX, alias(1)),
        (0, original),
        (0, "[2001:db8:64::1]:50001".parse().unwrap()),
    ] {
        assert_eq!(fixture.resolve(index, address), -2);
    }
    assert_eq!(fixture.resolve(0, alias(1)), 0);
    assert_eq!(fixture.inventory(), vec![original]);
}

#[test]
fn original_ipv6_cannot_be_remapped() {
    let original = "[2001:db8:2::20]:50000".parse().unwrap();
    let mut fixture = Fixture::new(&[original], Scenario::V6);
    assert_eq!(fixture.answer_result, 0);
    assert_eq!(fixture.resolve(0, alias(1)), -2);
    assert_eq!(fixture.inventory(), vec![original]);
}

#[test]
fn combined_endpoint_budget_counts_unique_addresses() {
    let mut fixture = Fixture::new(
        &[
            "198.51.100.20:50000".parse().unwrap(),
            "198.51.100.21:50000".parse().unwrap(),
        ],
        Scenario::V4,
    );
    assert_eq!(fixture.answer_result, 0);
    let originals = fixture.inventory();
    assert_eq!(originals.len(), 2);
    for index in 1..=97 {
        assert_eq!(fixture.resolve(0, alias(index)), 0);
    }
    for _ in 0..3 {
        assert_eq!(fixture.resolve(0, alias(1)), 0);
    }
    assert_eq!(fixture.resolve(0, alias(98)), 0);
    assert_eq!(fixture.resolve(0, alias(99)), -4);
    assert_eq!(fixture.resolve(0, alias(1)), 0);
    assert_eq!(fixture.resolve(1, alias(1)), 0);
    assert_eq!(fixture.resolve(1, alias(99)), -4);
    assert_eq!(fixture.inventory(), originals);
}

#[test]
fn ice_credentials_do_not_repeat_with_noncryptographic_rng_state() {
    let credentials = || {
        fastrand::seed(7);
        let client = Client(openclaw_rtc_create());
        assert!(!client.0.is_null());
        assert_eq!(unsafe { openclaw_rtc_offer(client.0) }, 0);
        let mut length = 0;
        let bytes = unsafe { openclaw_rtc_description(client.0, &mut length) };
        let text =
            std::str::from_utf8(unsafe { std::slice::from_raw_parts(bytes, length) }).unwrap();
        let offer = SdpOffer::from_sdp_string(text).unwrap();
        offer
            .session
            .ice_creds()
            .or_else(|| offer.media_lines.iter().find_map(|media| media.ice_creds()))
            .unwrap()
    };
    let first = credentials();
    let second = credentials();
    assert!(
        first.ufrag != second.ufrag && first.pass != second.pass,
        "ICE credentials must not repeat when noncryptographic RNG state repeats"
    );
}

#[test]
fn panic_retires_engine_without_losing_description() {
    let fixture = Fixture::new(&["198.51.100.20:50000".parse().unwrap()], Scenario::V4);
    assert_eq!(fixture.answer_result, 0);
    let description = || {
        let mut length = 0;
        let bytes = unsafe { openclaw_rtc_description(fixture.client.0, &mut length) };
        assert!(!bytes.is_null());
        unsafe { std::slice::from_raw_parts(bytes, length).to_vec() }
    };
    let expected = description();
    assert!(!expected.is_empty());
    assert_eq!(
        unsafe {
            operate(fixture.client.0, |_, _| {
                panic!("fixture RTC operation failed")
            })
        },
        -1
    );
    assert_eq!(unsafe { openclaw_rtc_timeout(fixture.client.0) }, -1);
    let mut address = OpenClawRTCAddress::default();
    assert_eq!(
        unsafe { openclaw_rtc_remote_address(fixture.client.0, 0, &mut address) },
        -1
    );
    assert_eq!(description(), expected);
}


#[test]
fn exposed_offer_advertises_the_receive_limit_and_preserves_fec() {
    let client = Client(openclaw_rtc_create());
    assert!(!client.0.is_null());
    assert_eq!(unsafe { openclaw_rtc_offer(client.0) }, 0);
    let mut length = 0;
    let pointer = unsafe { openclaw_rtc_description(client.0, &mut length) };
    let sdp = std::str::from_utf8(unsafe { std::slice::from_raw_parts(pointer, length) }).unwrap();
    let fmtp = sdp.lines().find(|line| line.starts_with("a=fmtp:111 ")).unwrap();
    assert!(fmtp.contains("maxaveragebitrate=24000"));
    assert!(fmtp.contains("useinbandfec=1"));
    assert!(sdp.contains("a=rtpmap:111 opus/48000/2"));
    assert!(sdp.contains("webrtc-datachannel"));
    assert!(SdpOffer::from_sdp_string(sdp).is_ok());
}

#[test]
fn receive_limit_only_changes_opus_audio_not_ice_other_codecs_or_sctp() {
    let original = "v=0\r\na=ice-ufrag:unchanged\r\nm=audio 9 UDP/TLS/RTP/SAVPF 109 0\r\na=rtpmap:109 opus/48000/2\r\na=fmtp:109 minptime=10;useinbandfec=1;maxaveragebitrate=64000\r\na=rtpmap:0 PCMU/8000\r\na=fmtp:0 other=1\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=fmtp:109 untouched=64000\r\n";
    let limited = limited_opus_offer(original).unwrap();
    assert_eq!(limited, original.replace("maxaveragebitrate=64000", "maxaveragebitrate=24000"));
    assert_eq!(limited_opus_offer(&limited).unwrap(), limited);
}

#[test]
fn receive_limit_adds_missing_fmtp_and_rejects_missing_or_ambiguous_opus() {
    let bare = "v=0\r\nm=audio 9 RTP/AVP 109\r\na=rtpmap:109 opus/48000/2\r\n";
    assert!(limited_opus_offer(bare).unwrap().contains("a=fmtp:109 maxaveragebitrate=24000\r\n"));
    assert!(limited_opus_offer("v=0\r\nm=audio 9 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n").is_err());
    assert!(limited_opus_offer(&(bare.to_owned() + "a=fmtp:109 minptime=10\r\na=fmtp:109 useinbandfec=1\r\n")).is_err());
}
