import CopyButton from './CopyButton';

export default function CopyCommand({ command }) {
  return (
    <div className="command">
      <code>
        <span className="prompt" aria-hidden="true">$</span> {command}
      </code>
      <CopyButton text={command} label="Copy command" />
    </div>
  );
}
