// A small highlighter for the code in the docs: JSON (and JSON lines), shell sessions and usage lines.

const JSON_TOKEN = /("(?:[^"\\]|\\.)*")(\s*:)?|(-?\b\d+(?:\.\d+)?\b)|([{}[\],])/g;

function json(text) {
  const out = [];
  let last = 0;
  JSON_TOKEN.lastIndex = 0;
  for (let m = JSON_TOKEN.exec(text); m; m = JSON_TOKEN.exec(text)) {
    const [all, str, colon, num, punc] = m;
    if (m.index > last) out.push(text.slice(last, m.index));
    if (str && colon) {
      out.push(
        <span className="tk-key" key={m.index}>
          {str}
        </span>,
        <span className="tk-punc" key={`${m.index}:`}>
          {colon}
        </span>,
      );
    } else if (str) {
      const v = str.slice(1, -1);
      const cls = v === 'deny' ? 'tk-deny' : v === 'allow' ? 'tk-allow' : 'tk-str';
      out.push(
        <span className={cls} key={m.index}>
          {str}
        </span>,
      );
    } else if (num) {
      out.push(
        <span className="tk-num" key={m.index}>
          {num}
        </span>,
      );
    } else {
      out.push(
        <span className="tk-punc" key={m.index}>
          {punc}
        </span>,
      );
    }
    last = m.index + all.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

// Placeholders and optional parts in a dimmer tone, flags in between.
function usage(line) {
  return line.split(/(<[^>]+>|\[[^\]]+\]|--[a-z][a-z-]*)/g).map((part, i) => {
    if (part.startsWith('<') || part.startsWith('[')) {
      return (
        <span className="tk-ph" key={i}>
          {part}
        </span>
      );
    }
    if (part.startsWith('--')) {
      return (
        <span className="tk-flag" key={i}>
          {part}
        </span>
      );
    }
    return part;
  });
}

function shell(text) {
  const lines = text.split('\n');
  const session = lines.some((l) => l.startsWith('$ '));
  return lines.map((line, i) => {
    let node;
    if (line.startsWith('$ ')) {
      const body = line.slice(2);
      const hash = body.search(/\s{2,}#/);
      node = (
        <>
          <span className="tk-prompt">$ </span>
          {usage(hash >= 0 ? body.slice(0, hash) : body)}
          {hash >= 0 ? <span className="tk-comment">{body.slice(hash)}</span> : null}
        </>
      );
    } else if (line.startsWith('#')) {
      node = <span className="tk-comment">{line}</span>;
    } else if (session) {
      node = <span className={/^(error|refused)\b/.test(line) ? 'tk-err' : 'tk-out'}>{line}</span>;
    } else {
      node = usage(line);
    }
    return (
      <span key={i}>
        {node}
        {i < lines.length - 1 ? '\n' : null}
      </span>
    );
  });
}

export function highlight(text) {
  if (typeof text !== 'string') return text;
  return text.trimStart().startsWith('{') ? json(text) : shell(text);
}
