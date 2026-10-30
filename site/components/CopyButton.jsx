'use client';

import { useState } from 'react';
import { IconCheck, IconCopy } from './Icons';

export default function CopyButton({ text, label = 'Copy', floating = false }) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      setCopied(false);
    }
  }

  return (
    <button
      type="button"
      className={`copy-btn${floating ? ' copy-floating' : ''}${copied ? ' is-copied' : ''}`}
      onClick={copy}
      aria-label={copied ? 'Copied' : label}
    >
      {copied ? <IconCheck size={14} /> : <IconCopy size={14} />}
    </button>
  );
}
