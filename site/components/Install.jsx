import CopyCommand from './CopyCommand';
import { IconArrowRight, IconPenguin } from './Icons';
import { RELEASE } from '../content/site';

// The two install commands from the release notes, and the Linux step they do not cover.
export default function Install() {
  return (
    <div className="install">
      <div className="install-row">
        <p className="install-label">
          npm <span>Node.js 22 or later</span>
        </p>
        <CopyCommand command={RELEASE.npm} />
      </div>
      <div className="install-row">
        <p className="install-label">
          Homebrew <span>macOS and Linux</span>
        </p>
        <CopyCommand command={RELEASE.brew} />
      </div>
      <div className="install-note">
        <IconPenguin size={16} />
        <p>
          Both install the CLI only. On Debian 13 (x86_64), task scopes also need a small helper with its own setup,
          from a checkout of v{RELEASE.version}. The setup runs with sudo, and again after each reboot. Neither npm nor
          Homebrew runs it.{' '}
          <a href={RELEASE.linuxSetup}>
            Steps in docs/linux.md
            <IconArrowRight size={13} />
          </a>
        </p>
      </div>
    </div>
  );
}
