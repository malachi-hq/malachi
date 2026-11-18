# Changelog

Every release of Malachi, newest first. The release workflow writes each section from
`scripts/release-notes.sh --changes-only` in the commit that bumps the version.

## v0.28.4 (2026-11-17)

### Performance

- batch the sealed copy integrity probe (#372)

## v0.28.3 (2026-11-16)

### Performance

- restart recovery blocks broker loop (#371)

### Other

- release only user facing changes (#370)

## v0.28.2 (2026-11-16)

### Documentation

- record replenishment coordinator divergence (#365)

## v0.28.1 (2026-11-16)

### Documentation

- state majority ack durability (#361)

## v0.28.0 (2026-11-14)

### Features

- data subject purge requests (#348)

## v0.27.0 (2026-11-14)

### Features

- legal hold retention (#349)

## v0.26.2 (2026-11-14)

### Fixes

- dashboard csp without unsafe inline (#347)

## v0.26.1 (2026-11-14)

### Fixes

- oci sweep settles after destroy (#346)

## v0.26.0 (2026-11-14)

### Features

- batch native storage (#344)

## v0.25.0 (2026-11-14)

### Features

- purge range to point (#343)

## v0.24.0 (2026-11-14)

### Features

- console read api (#342)

## v0.23.6 (2026-11-13)

### Other

- credentials off process argv (#340)

## v0.23.5 (2026-11-13)

### Dependencies

- **deps:** bump ra to 3.2.0 (#338)

## v0.23.4 (2026-11-13)

### Other

- deps toolchain otp29 2026 11 12 (#339)

## v0.23.3 (2026-11-13)

### Other

- deps hex 2026 11 12 (#335)

## v0.23.2 (2026-11-12)

### Other

- deps docker alpine 2026 11 12 (#336)
- deps actions 2026 11 12 (#337)

## v0.23.1 (2026-11-12)

### Other

- deps hex auth 2026 11 12 (#334)

## v0.23.0 (2026-11-12)

### Features

- northguard produce streams (#310)

## v0.22.9 (2026-11-11)

### Fixes

- publish results through the release App, retry on no capacity, and replace the orchestrator safely (#326)

## v0.22.8 (2026-11-11)

### Fixes

- fit the OCI orchestrator user_data in 32 KB and release through a GitHub App (#320)

### Other

- **deploy:** add an OCI Always Free ephemeral cluster example (#316)

## v0.22.7 (2026-11-04)

### Other

- **hex:** prepare package metadata and pin codecov action (#305)

## v0.22.6 (2026-10-31)

### Other

- funding and oss programs (#304)

## v0.22.5 (2026-10-28)

### Other

- landing page (#301)

## v0.22.4 (2026-10-28)

### Other

- pin settling convergence on recorded seals (#296)

## v0.22.3 (2026-10-27)

### Other

- bounded adversarial review (#300)

## v0.22.2 (2026-10-22)

### Other

- remove unreachable metadata policy commands (#297)

## v0.22.1 (2026-10-21)

### Fixes

- seal marker trust fsync (#295)

## v0.22.0 (2026-10-07)

### Features

- time based segment roll (#291)

## v0.21.1 (2026-10-07)

### Fixes

- image healthcheck probes ipv6 localhost (#289)

## v0.21.0 (2026-10-06)

### Features

- console roles (#288)

## v0.20.0 (2026-10-06)

### Features

- design token pipeline (#280)

## v0.19.5 (2026-10-06)

### Fixes

- single node restart deletes acknowledged data (#281)

## v0.19.4 (2026-10-05)

### Other

- dependency updates skill (#279)

## v0.19.3 (2026-10-01)

### Other

- realistic loadtest payloads (#277)

## v0.19.2 (2026-10-01)

### Other

- multi topic subscriber teardown (#276)

## v0.19.1 (2026-10-01)

### Other

- **chaos:** certify a rolling upgrade and its rollback, and fix what the drill found (#274)

## v0.19.0 (2026-10-01)

### Features

- pr agent review skill (#272)

## v0.18.0 (2026-09-30)

### Features

- console http endpoint (#265)

## v0.17.2 (2026-09-29)

### Fixes

- **loadtest:** close a connection whose authentication was refused (#271)

## v0.17.1 (2026-09-29)

### Fixes

- loadtest stream subscribe drop (#267)

## v0.17.0 (2026-09-29)

### Features

- per topic retention api (#266)

## v0.16.5 (2026-09-29)

### Fixes

- dockerfile copy priv (#264)

## v0.16.4 (2026-09-28)

### Fixes

- dashboard header count bound (#260)

## v0.16.3 (2026-09-28)

### Fixes

- dashboard content length overrun (#259)

## v0.16.2 (2026-09-28)

### Fixes

- separate dashboard api rate limit (#261)

## v0.16.1 (2026-09-28)

### Fixes

- broker live bootstrap vnodes (#262)

## v0.16.0 (2026-09-28)

### Features

- broker metadata view staleness (#258)

## v0.15.0 (2026-09-27)

### Other

- dev environment isolation (#257)

## v0.14.4 (2026-09-26)

### Fixes

- vnode manager live placement (#246)

## v0.14.3 (2026-09-26)

### Fixes

- replica record past sealed end (#245)

## v0.14.2 (2026-09-26)

### Fixes

- retention delete ignores control plane (#247)

## v0.14.1 (2026-09-26)

### Fixes

- broker reconcile off loop (#238)

## v0.14.0 (2026-09-24)

### Features

- node capability advertisement (#236)

## v0.13.2 (2026-09-22)

### Fixes

- one canonical ip formatter (#221)

## v0.13.1 (2026-09-22)

### Fixes

- loadtest fanout error reasons (#214)

## v0.13.0 (2026-09-21)

### Features

- retention metrics and expiry signal (#216)

## v0.12.2 (2026-09-21)

### Fixes

- metadata machine versioning (#215)

## v0.12.1 (2026-09-20)

### Fixes

- replication server unknown cast (#213)

## v0.12.0 (2026-09-20)

### Features

- data format marker (#211)

## v0.11.2 (2026-09-19)

### Fixes

- **rate_limiter:** stop the publish quota admitting over its limit (#151) (#176)

## v0.11.1 (2026-09-18)

### Other

- **chaos:** diagnose and fix the storage drill's physical convergence invariant (#172)

## v0.11.0 (2026-09-18)

### Other

- **storage:** record group-commit flush latency and scrape it in the benchmarks (#174)

## v0.10.1 (2026-09-17)

### Other

- **bench:** add a real-disk mode to the docker cluster benchmark. (#163)

## v0.10.0 (2026-09-16)

### Other

- **bench:** declare the flush regime the Elixir benchmarks run at (#162)

## v0.9.7 (2026-09-16)

### Performance

- **bench:** sweep the flush size so the ceiling is a curve. (#160)

## v0.9.6 (2026-09-15)

### Documentation

- **contributing:** the fdatasync example left out the question it opened (#159)

## v0.9.5 (2026-09-15)

### Documentation

- **template:** the Risks and open questions section is required, not optional (#158)

## v0.9.4 (2026-09-15)

### Other

- **repo:** write down the procedure for starting work, and the bar for finishing it (#155)

## v0.9.3 (2026-09-14)

### Fixes

- storage io error propagation (#153)

## v0.9.2 (2026-09-12)

### Fixes

- size the blank-tail check by what it costs on Linux (#150)

## v0.9.1 (2026-09-11)

### Performance

- segment preallocation (#146)

## v0.9.0 (2026-09-09)

### Features

- enforce publish and subscribe rate limits (#137)

## v0.8.27 (2026-09-09)

### Fixes

- durable vnode ring across restart (#138)

## v0.8.26 (2026-09-09)

### Fixes

- **cluster:** reconcile a fenced store with metadata that still calls it active (#121) (#139)

## v0.8.25 (2026-09-08)

### Fixes

- **scripts:** install lefthook from a checksum-verified release instead of piping curl into bash (#69) (#132)

## v0.8.24 (2026-09-07)

### Fixes

- **cluster:** fence the parent's write head from the control plane, not the cache (#122)

## v0.8.23 (2026-09-07)

### Fixes

- **dashboard:** add a deny-all Permissions-Policy header (#68) (#123)

## v0.8.22 (2026-09-07)

### Fixes

- **cluster:** seal a segment whose primary died instead of promoting a replica (#93)

## v0.8.21 (2026-09-05)

### Fixes

- **chaos:** stop the durability checker from reading a visibility lag as a lost write (#92)

## v0.8.20 (2026-09-04)

### Fixes

- **client:** verify the server certificate and hostname when TLS is on (#90)

## v0.8.19 (2026-09-04)

### Other

- stop linked processes quietly in teardown so the shutdown race cannot fail a green suite (#89)

## v0.8.18 (2026-09-04)

### Fixes

- restart coordinators for led vnodes (#79)

## v0.8.17 (2026-09-03)

### Other

- **cluster:** widen the no-quorum timer budget so a healthy commit cannot lose the race (#78)

## v0.8.16 (2026-09-03)

### Fixes

- **cluster:** reject a control-plane command that targets another topic's range (#77)

## v0.8.15 (2026-09-02)

### Fixes

- node client cap server frame length (#76)

## v0.8.14 (2026-09-02)

### Documentation

- **auth:** correct the durability claims about the generated admin and warn at boot (#74)

## v0.8.13 (2026-08-28)

### Fixes

- **security:** take the dashboard cookie Secure flag off the broker TLS setting (#58)

## v0.8.12 (2026-08-28)

### Fixes

- security make sobelow gate enforce and bound consume cursor (#57)

## v0.8.11 (2026-08-27)

### Dependencies

- **deps:** bump ra from 2.17.3 to 3.1.10 (#6)

## v0.8.10 (2026-08-27)

### Fixes

- **cluster:** consistent queries as an MFA, unblocking the ra 3 bump (#55)

## v0.8.9 (2026-08-27)

### Other

- **ci:** bump github/codeql-action to v4 for the SARIF uploads (#54)

## v0.8.8 (2026-08-27)

### Other

- **ci:** bump actions/configure-pages from 5 to 6 (#4)

## v0.8.7 (2026-08-27)

### Other

- **ci:** bump gitleaks/gitleaks-action from 2 to 3 (#24)

## v0.8.6 (2026-08-27)

### Other

- **ci:** bump actions/dependency-review-action from 3 to 5 (#23)

## v0.8.5 (2026-08-27)

### Other

- **ci:** bump actions/upload-artifact from 4 to 7 (#7)

## v0.8.4 (2026-08-27)

### Other

- **docs:** the benchmark page reads the pipeline that already updat… (#53)

## v0.8.3 (2026-08-26)

### Other

- two steps that only run after a merge, and so only failed after one (#52)

## v0.8.2 (2026-08-26)

### Other

- bench, chaos, docs and impl (#48)

## v0.8.1 (2026-08-21)

### Fixes

- survive node restarts over persisted state (#44)

## v0.8.0 (2026-08-17)

### Features

- group commit produce path (#28)

## v0.7.10 (2026-08-11)

### Documentation

- **site:** link the benchmark dashboard from the ExDoc sidebar (#27)

## v0.7.9 (2026-08-10)

### Other

- docs and benchmark (#26)

## v0.7.8 (2026-08-05)

### Dependencies

- **deps:** bump ex_doc, benchee, stream_data and three CI actions (#22)

## v0.7.7 (2026-08-05)

### Other

- session user agent binding (#21)

## v0.7.6 (2026-07-31)

### Documentation

- **security:** record a VEX not-affected assessment for CVE-2025-60876 (#20)

## v0.7.5 (2026-07-30)

### Fixes

- **docker:** drop curl from the runtime image to clear its CVEs (#19)

## v0.7.4 (2026-07-30)

### Fixes

- **docs:** version the changelog to match the published releases (#18)

## v0.7.3 (2026-07-29)

### Fixes

- **docs:** use a monotonic counter for mermaid render ids (#17)

## v0.7.2 (2026-07-29)

### Documentation

- render mermaid on ExDoc swup navigation, not just full loads (#16)

## v0.7.1 (2026-07-29)

### Fixes

- mermaid node labels rendering as "Unsupported markdown: list" (#15)

## v0.7.0 (2026-07-29)

### Other

- unify benchmarks under benchmark/ (drop the separate bench/ dir) (#14)

## v0.6.2 (2026-07-29)

### Other

- retry mix deps.get to tolerate transient Hex failures (#13)

## v0.6.1 (2026-07-29)

### Fixes

- **ci:** use the real Docker Hub credentials in the release workflow (#12)

## v0.6.0 (2026-07-28)

### Features

- reimplementation of LinkedIn NorthGuard (#1)

### Other

- just a commit
