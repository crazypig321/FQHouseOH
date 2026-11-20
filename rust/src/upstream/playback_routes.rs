//! Playback door health and identity-rotation pacing.
//!
//! Ported from `N3urda/hongguoTV` (`kotlin-tv/core/.../PlaybackRoutes.kt` and
//! the `streamLadder` ladder): every playback door keeps its own health entry,
//! an empty HTTP 200 body parks that door for [EMPTY_COOLDOWN], non-empty
//! failures park it for [ERROR_COOLDOWN], and consecutive all-empty rounds
//! eventually justify one anonymous-identity rotation.
//!
//! State is process-wide, monotonic-clock based, and stores only door/host
//! labels plus timestamps: no request parameters, identities, addresses or
//! response bytes. Callers that need deterministic behaviour pass their own
//! `now_ms`; nothing reads a wall clock.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

/// An empty body parks a door long enough that a retry loop cannot hammer it.
pub(crate) const EMPTY_COOLDOWN: Duration = Duration::from_secs(30);
/// A non-empty, non-auth failure (timeout, 5xx, unverified host) parks it briefly.
pub(crate) const ERROR_COOLDOWN: Duration = Duration::from_secs(5);
/// After a rotation that still produced empty models, wait this long before
/// rotating again: a replacement identity is scarce and worth reusing.
pub(crate) const ROTATE_COOLDOWN_SETTLED: Duration = Duration::from_secs(30);
/// After a rotation that could not even register, retry sooner.
pub(crate) const ROTATE_COOLDOWN_FAILED: Duration = Duration::from_secs(5);
/// Consecutive all-empty rounds before a foreground request rotates identity.
pub(crate) const EMPTY_ROTATE_ROUNDS: u32 = 2;

/// The v5 signed player door (single host, the one the app ships).
pub(crate) const V5_PLAYER_HOST: &str = "https://api5-normal-sinfonlinea.fqnovel.com";
/// The signed `GET video_tab` fallback door.
///
/// The `hl`/`lf` hosts were dropped: on-device sampling showed every host
/// answering `HTTP 200` with zero bytes, so the extra hosts only added latency.
pub(crate) const VIDEO_TAB_HOSTS: [&str; 1] = ["https://api5-normal-sinfonlineb.fqnovel.com"];

/// Which upstream door a route addresses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Door {
    /// `POST /novel/player/multi_video_model/player/v1` with the v5 signature.
    V5Player,
    /// `GET /reading/bookapi/video_tab/multi_video_model/v1/` signed with the
    /// regular request signer; the official app keeps this path.
    VideoTab,
}

/// One independently-tracked playback route.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct Route {
    pub door: Door,
    /// Index into the door's host table.
    pub host_index: u8,
}

impl Route {
    pub fn host(self) -> &'static str {
        match self.door {
            Door::V5Player => V5_PLAYER_HOST,
            Door::VideoTab => VIDEO_TAB_HOSTS
                .get(self.host_index as usize)
                .copied()
                .unwrap_or(VIDEO_TAB_HOSTS[0]),
        }
    }

    /// Short label for diagnostics; hosts themselves are not logged.
    pub fn tag(self) -> &'static str {
        match self.door {
            Door::V5Player => "v5",
            Door::VideoTab => "tab-b",
        }
    }
}

/// Every route the playback chain may use, in preference order.
pub(crate) fn routes() -> Vec<Route> {
    let mut all = vec![Route {
        door: Door::V5Player,
        host_index: 0,
    }];
    all.extend((0..VIDEO_TAB_HOSTS.len()).map(|index| Route {
        door: Door::VideoTab,
        host_index: index as u8,
    }));
    all
}

#[derive(Debug, Clone, Copy, Default)]
struct Health {
    last_success_ms: Option<u64>,
    blocked_until_ms: u64,
    empty: bool,
}

/// Process-wide playback health plus identity-rotation pacing.
#[derive(Debug, Default)]
pub(crate) struct PlaybackRouteState {
    health: HashMap<Route, Health>,
    empty_rounds: u32,
    last_rotate_ms: Option<u64>,
    rotate_result: Option<bool>,
    rotations: u32,
}

impl PlaybackRouteState {
    /// Healthy routes first, blocked ones skipped entirely.
    ///
    /// A speculative (prefetch) caller never probes a cooling route: background
    /// work must not spend the failure budget the foreground needs.
    pub fn plan(&self, now_ms: u64, speculative: bool) -> Vec<Route> {
        let all = routes();
        let mut available: Vec<Route> = all
            .iter()
            .copied()
            .filter(|route| self.health_for(*route).blocked_until_ms <= now_ms)
            .collect();
        available.sort_by(|a, b| {
            self.health_for(*b)
                .last_success_ms
                .cmp(&self.health_for(*a).last_success_ms)
        });
        if speculative {
            return available.into_iter().take(1).collect();
        }
        if available.is_empty() {
            // Everything is cooling down: probe the earliest recovery only.
            return all
                .iter()
                .copied()
                .min_by_key(|route| self.health_for(*route).blocked_until_ms)
                .map(|route| vec![route])
                .unwrap_or_default();
        }
        available
    }

    fn health_for(&self, route: Route) -> Health {
        self.health.get(&route).copied().unwrap_or_default()
    }

    /// True while this door is parked by a cooldown.
    pub fn parked(&self, route: Route, now_ms: u64) -> bool {
        self.health_for(route).blocked_until_ms > now_ms
    }

    /// Every route is parked because of an empty body.
    pub fn exhausted(&self, now_ms: u64) -> bool {
        routes().iter().all(|route| {
            let health = self.health_for(*route);
            health.empty && health.blocked_until_ms > now_ms
        })
    }

    pub fn success(&mut self, route: Route, now_ms: u64) {
        let health = self.health.entry(route).or_default();
        health.last_success_ms = Some(now_ms);
        health.blocked_until_ms = 0;
        health.empty = false;
    }

    pub fn failed(&mut self, route: Route, now_ms: u64, empty: bool) {
        let cooldown = if empty {
            EMPTY_COOLDOWN
        } else {
            ERROR_COOLDOWN
        };
        let health = self.health.entry(route).or_default();
        health.blocked_until_ms = now_ms.saturating_add(cooldown.as_millis() as u64);
        health.empty = empty;
    }

    /// One completed round: did *every* attempt end in an empty body?
    pub fn note_round(&mut self, all_empty: bool) {
        if all_empty {
            self.empty_rounds = self.empty_rounds.saturating_add(1);
        } else {
            self.empty_rounds = 0;
        }
    }

    pub fn empty_rounds(&self) -> u32 {
        self.empty_rounds
    }

    /// Rotation pacing alone: a foreground caller, and a previous rotation that
    /// has settled. Independent of the empty streak so an in-round bail-out can
    /// reuse it.
    pub fn rotation_paced(&self, now_ms: u64, speculative: bool) -> bool {
        if speculative {
            return false;
        }
        let cooldown = match self.rotate_result {
            Some(false) => ROTATE_COOLDOWN_FAILED,
            _ => ROTATE_COOLDOWN_SETTLED,
        };
        match self.last_rotate_ms {
            None => true,
            Some(last) => now_ms.saturating_sub(last) >= cooldown.as_millis() as u64,
        }
    }

    /// A foreground request may rotate identity when the empty streak is long
    /// enough and the previous rotation has settled.
    pub fn rotate_due(&self, now_ms: u64, speculative: bool) -> bool {
        self.empty_rounds >= EMPTY_ROTATE_ROUNDS && self.rotation_paced(now_ms, speculative)
    }

    pub fn note_rotate(&mut self, now_ms: u64, registered: bool) {
        self.last_rotate_ms = Some(now_ms);
        self.rotate_result = Some(registered);
        if registered {
            self.rotations = self.rotations.saturating_add(1);
        }
    }

    pub fn rotations(&self) -> u32 {
        self.rotations
    }
}

fn state() -> &'static Mutex<PlaybackRouteState> {
    static STATE: OnceLock<Mutex<PlaybackRouteState>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(PlaybackRouteState::default()))
}

fn process_start() -> Instant {
    static START: OnceLock<Instant> = OnceLock::new();
    *START.get_or_init(Instant::now)
}

/// Monotonic milliseconds since this process started; never a wall clock.
pub(crate) fn now_ms() -> u64 {
    process_start().elapsed().as_millis() as u64
}

/// Runs `f` against the shared state.
pub(crate) fn with_state<R>(f: impl FnOnce(&mut PlaybackRouteState) -> R) -> R {
    let mut guard = state().lock().unwrap_or_else(|error| error.into_inner());
    f(&mut guard)
}

/// Clears all health and pacing state.
///
/// Exposed for integration tests so one scenario cannot inherit another's
/// cooldowns; production never calls it.
#[doc(hidden)]
pub fn reset_state_for_tests() {
    with_state(|state| *state = PlaybackRouteState::default());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(duration: Duration) -> u64 {
        duration.as_millis() as u64
    }

    #[test]
    fn empty_body_parks_a_door_for_thirty_seconds_and_success_clears_it() {
        let mut state = PlaybackRouteState::default();
        let v5 = routes()[0];
        state.failed(v5, 1_000, true);
        assert!(!state
            .plan(1_000 + ms(EMPTY_COOLDOWN) - 1, false)
            .contains(&v5));
        assert!(state.plan(1_000 + ms(EMPTY_COOLDOWN), false).contains(&v5));
        state.success(v5, 2_000);
        let health = state.health_for(v5);
        assert_eq!(health.blocked_until_ms, 0);
        assert!(!health.empty);
        // The successful door is offered first.
        assert_eq!(state.plan(3_000, false).first(), Some(&v5));
    }

    #[test]
    fn non_empty_failures_only_park_a_door_briefly() {
        let mut state = PlaybackRouteState::default();
        let tab = Route {
            door: Door::VideoTab,
            host_index: 0,
        };
        state.failed(tab, 10_000, false);
        assert!(!state.plan(10_000, false).contains(&tab));
        assert!(state
            .plan(10_000 + ms(ERROR_COOLDOWN), false)
            .contains(&tab));
        // A briefly-parked door is not "exhausted": only empty bodies are.
        assert!(!state.exhausted(10_000));
    }

    #[test]
    fn speculative_planning_never_probes_a_cooling_door() {
        let mut state = PlaybackRouteState::default();
        for route in routes() {
            state.failed(route, 0, true);
        }
        assert!(state.plan(1, true).is_empty());
        // Foreground still gets one earliest-recovery probe.
        assert_eq!(state.plan(1, false).len(), 1);
        assert!(state.exhausted(1));
    }

    #[test]
    fn exhausted_needs_every_door_empty_and_blocked() {
        let mut state = PlaybackRouteState::default();
        let all = routes();
        for route in &all[..all.len() - 1] {
            state.failed(*route, 0, true);
        }
        assert!(!state.exhausted(1));
        state.failed(*all.last().unwrap(), 0, true);
        assert!(state.exhausted(1));
    }

    #[test]
    fn rotation_needs_two_empty_rounds_and_a_foreground_caller() {
        let mut state = PlaybackRouteState::default();
        state.note_round(true);
        assert!(
            !state.rotate_due(1_000, false),
            "one empty round is not enough"
        );
        assert!(!state.rotate_due(1_000, true), "prefetch must never rotate");
        state.note_round(true);
        assert!(state.rotate_due(1_000, false));
        // A non-empty round resets the streak.
        state.note_round(false);
        assert_eq!(state.empty_rounds(), 0);
        assert!(!state.rotate_due(1_000, false));
    }

    #[test]
    fn a_settled_rotation_costs_thirty_seconds_and_a_failed_one_five() {
        let mut state = PlaybackRouteState::default();
        state.note_round(true);
        state.note_round(true);

        state.note_rotate(5_000, false);
        assert!(!state.rotate_due(5_000 + ms(ROTATE_COOLDOWN_FAILED) - 1, false));
        assert!(state.rotate_due(5_000 + ms(ROTATE_COOLDOWN_FAILED), false));
        assert_eq!(state.rotations(), 0);

        state.note_rotate(20_000, true);
        assert!(!state.rotate_due(20_000 + ms(ROTATE_COOLDOWN_SETTLED) - 1, false));
        assert!(state.rotate_due(20_000 + ms(ROTATE_COOLDOWN_SETTLED), false));
        assert_eq!(state.rotations(), 1);
    }

    #[test]
    fn pacing_alone_blocks_a_second_in_round_rotation() {
        // A fully parked round may rotate on its own, but never twice inside the
        // cooldown: the pool is bounded, so identity churn has to stay rare.
        let mut state = PlaybackRouteState::default();
        state.note_rotate(1_000, true);
        assert!(!state.rotation_paced(1_000, false));
        assert!(!state.rotation_paced(1_000 + ms(ROTATE_COOLDOWN_SETTLED) - 1, false));
        assert!(state.rotation_paced(1_000 + ms(ROTATE_COOLDOWN_SETTLED), false));
        assert!(!state.rotation_paced(9_999_999, true));
    }

    #[test]
    fn a_door_is_parked_exactly_until_its_cooldown_lapses() {
        let mut state = PlaybackRouteState::default();
        let v5 = routes()[0];
        assert!(!state.parked(v5, 1_000));
        state.failed(v5, 1_000, true);
        assert!(state.parked(v5, 1_001));
        assert!(!state.parked(v5, 1_000 + ms(EMPTY_COOLDOWN)));
    }

    #[test]
    fn route_tags_stay_short_and_address_free() {
        let tags: Vec<&str> = routes().iter().map(|route| route.tag()).collect();
        assert_eq!(tags, vec!["v5", "tab-b"]);
        assert!(tags.iter().all(|tag| !tag.contains("fqnovel")));
        assert!(routes()
            .iter()
            .all(|route| route.host().starts_with("https://api5-normal-")));
    }
}
