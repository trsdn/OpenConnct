# Summary

<!-- What changes and why. Link the issue, for example "Closes #12". -->

## Type of change

- [ ] Documentation only
- [ ] DSP core (`Core/Sources/OpenConnctDSP`)
- [ ] Audio engine, device handling or drift control (`App/OpenConnctApp/Audio`)
- [ ] HAL plug-in (`App/OpenConnctDriver`)
- [ ] User interface (`App/OpenConnctApp/Views`)
- [ ] Build, packaging or CI

## Validation

<!-- Paste or summarize results. -->

- [ ] `make test`
- [ ] `make test-driver`
- [ ] `make build`
- [ ] Checked on real hardware

## Realtime safety

<!-- Required if anything reachable from an audio callback changed. Write "Not affected" otherwise. -->

- [ ] No allocation, locks, logging, or Objective-C/Swift runtime traffic was
      added to a render or input callback.
- [ ] No unbounded work was added to a callback.
- [ ] UI communication still goes through lock-free queues or atomics only.

## Plug-in safety

<!-- Required if `App/OpenConnctDriver` changed. Write "Not affected" otherwise. -->

- [ ] The plug-in remains a dependency-free loopback: no DSP, no allocation, no
      locks, no runtime.
- [ ] No new IPC mechanism was introduced.
- [ ] `make test-driver` still passes.

## Measurements

<!--
If you claim a performance or audio-quality change, give the numbers and say
whether they came from a debug or a release build — they differ by roughly an
order of magnitude. Drift claims need a soak of at least fifteen minutes.
-->

## Documentation

- [ ] `README.md` updated, or not affected.
- [ ] `SECURITY.md` updated, or not affected.
- [ ] `CONTRIBUTING.md` updated, or not affected.
