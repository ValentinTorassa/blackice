# Application filter cgroup attachment decision

Status: implemented in the Linux app-filter follow-up branch; installation remains subject to the security
review and disposable-VM gate. This records the application-scopes ADR's S3 decision and the later H1 listener
guard. It does not authorize a host installation.

The five application socket hooks attach with legacy attachment at `/sys/fs/cgroup/user.slice`, rather than
at `user-<uid>.slice`. A per-user slice can disappear after its last session logs out. Lingering is not an
enforcement guarantee: disabling it and logging in again must not leave a saved armed policy without its
hooks. The parent `user.slice` survives that per-user session lifecycle. Reboot is a separate limit: pins
are in `/run`, and this version reports `disarmed_by_reboot` without automatically arming again.

Every user's session under `user.slice` traverses the connect4/6, sendmsg4/6 and socket-create programs.
Only the configured owner's real UID acquires a new executable tag; descendants retain inherited tags
even if their UID changes. Untagged sockets keep their ordinary network access, except for the reserved
application listener ports. These hooks therefore affect other users' sessions too; they are not a
private per-user firewall or a policy that denies every unlisted application.

Two additional connect4/6 guards attach at the cgroup root with `ALLOW_MULTI`. Cron, at and system services
can run outside `user.slice`; without the root guards, an untagged process there could reach an application's
listener and have its requests attributed to that app. The guards only restrict reserved local listener
ports 760–774, including Linux's unspecified-address and mapped-address loopback aliases. Other traffic
passes unchanged. This does not apply the full domain policy to sockets created outside `user.slice`.

Fresh arming requires the relevant hooks to be vacant. Recovery verifies the exact program IDs at all
seven hooks; a foreign program or missing attachment refuses recovery. Authorized off and root teardown
detach only the verified pinned programs. The root guard does not make delegated work through another
service, inherited sockets or rootless-container relays part of the app's containment boundary.

Validation must cover logout/login, another user's session, cron and a system service, listener aliases,
and recovery/off/teardown with all seven hooks. Unit models check verdicts and unchanged non-listener
contexts; they do not replace those installed-kernel checks on the candidate commit.
