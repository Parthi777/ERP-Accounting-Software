'use client';

import * as React from 'react';
import { Check, ChevronDown, Search, X } from 'lucide-react';

import { cn } from '@/lib/utils';

export interface SearchSelectOption {
  readonly id: string;
  readonly label: string;
}

/**
 * A picker you can type into — spec §8 ("search-first", "keyboard friendly").
 *
 * A native <select> is fine for six payment modes and unusable for six thousand
 * customers: it has no filtering, so finding someone means scrolling a list
 * ordered by whatever the query returned. Every entity picker in this product
 * grows with the dealer's business, so every one of them eventually hits that.
 *
 * ── Why it writes to a hidden input ─────────────────────────────────────────
 *
 * Most of these pickers sit inside a plain `<form method="get">` that the server
 * reads — the customer ledger, the statement filters. Replacing the select with
 * component state alone would break that. The visible control is a text box for
 * filtering; the value the form submits lives in a hidden input of the same
 * `name` the select had, so every caller keeps working unchanged.
 *
 * ── Keyboard ────────────────────────────────────────────────────────────────
 *
 * ↑/↓ move, Enter picks, Escape closes and restores what was chosen. Typing
 * filters on both the label and the code within it, because a cashier with a
 * customer ID in hand should not have to know whether it comes before the name.
 */
export function SearchSelect({
  name,
  options,
  defaultValue = '',
  placeholder,
  id,
  className,
  /** Submits the enclosing form as soon as something is picked. */
  submitOnSelect = false,
  onChange,
}: {
  readonly name: string;
  readonly options: readonly SearchSelectOption[];
  readonly defaultValue?: string;
  readonly placeholder?: string;
  readonly id?: string;
  readonly className?: string;
  readonly submitOnSelect?: boolean;
  readonly onChange?: (id: string) => void;
}) {
  const inputId = id ?? name;
  const [selected, setSelected] = React.useState(defaultValue);
  const [query, setQuery] = React.useState('');
  const [open, setOpen] = React.useState(false);
  const [active, setActive] = React.useState(0);

  const rootRef = React.useRef<HTMLDivElement>(null);
  const inputRef = React.useRef<HTMLInputElement>(null);
  const hiddenRef = React.useRef<HTMLInputElement>(null);

  const selectedOption = options.find((o) => o.id === selected) ?? null;

  const matches = React.useMemo(() => {
    const term = query.trim().toLowerCase();
    if (!term) return options;
    // Every whitespace-separated word must appear somewhere, so "ram 975"
    // finds "Ramesh · 9750499084" without the order mattering.
    const words = term.split(/\s+/);
    return options.filter((o) => {
      const haystack = o.label.toLowerCase();
      return words.every((w) => haystack.includes(w));
    });
  }, [options, query]);

  // Close on a click elsewhere. Escape is handled on the input itself, because
  // a global listener would also fire for dialogs stacked above this.
  React.useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) {
        setOpen(false);
        setQuery('');
      }
    };
    document.addEventListener('pointerdown', onPointerDown);
    return () => document.removeEventListener('pointerdown', onPointerDown);
  }, [open]);

  const choose = (option: SearchSelectOption | null) => {
    setSelected(option?.id ?? '');
    setQuery('');
    setOpen(false);
    onChange?.(option?.id ?? '');

    if (submitOnSelect) {
      // The hidden input is what the form reads, and React has not flushed the
      // new value yet — so set it directly before asking the form to submit.
      if (hiddenRef.current) hiddenRef.current.value = option?.id ?? '';
      hiddenRef.current?.form?.requestSubmit();
    }
  };

  const onKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      if (!open) {
        setOpen(true);
        setActive(0);
        return;
      }
      setActive((current) => {
        const next = event.key === 'ArrowDown' ? current + 1 : current - 1;
        if (next < 0) return matches.length - 1;
        if (next >= matches.length) return 0;
        return next;
      });
      return;
    }

    if (event.key === 'Enter' && open) {
      event.preventDefault();
      const option = matches[active];
      if (option) choose(option);
      return;
    }

    if (event.key === 'Escape') {
      event.preventDefault();
      setOpen(false);
      setQuery('');
      return;
    }
  };

  return (
    <div ref={rootRef} className={cn('relative', className)}>
      <input ref={hiddenRef} type="hidden" name={name} value={selected} readOnly />

      <div className="relative">
        <Search
          className="pointer-events-none absolute left-3 top-1/2 size-3.5 -translate-y-1/2 text-ink-400"
          aria-hidden
        />
        <input
          ref={inputRef}
          id={inputId}
          type="text"
          role="combobox"
          aria-expanded={open}
          aria-controls={`${inputId}-list`}
          aria-autocomplete="list"
          autoComplete="off"
          className="h-9 w-full rounded-lg border border-ink-200 bg-white pl-8 pr-14 text-sm shadow-sm outline-none focus:border-brand-400 focus:ring-2 focus:ring-brand-100"
          placeholder={placeholder ?? 'Type to search…'}
          // Closed, it reads as the chosen value; open, it is the search term.
          value={open ? query : (selectedOption?.label ?? '')}
          onChange={(e) => {
            setQuery(e.target.value);
            setOpen(true);
            setActive(0);
          }}
          onFocus={() => setOpen(true)}
          onKeyDown={onKeyDown}
        />

        <div className="absolute right-2 top-1/2 flex -translate-y-1/2 items-center gap-1">
          {selectedOption && (
            <button
              type="button"
              aria-label="Clear"
              className="rounded p-0.5 text-ink-400 hover:bg-ink-100 hover:text-ink-600"
              onClick={() => {
                choose(null);
                inputRef.current?.focus();
              }}
            >
              <X className="size-3.5" aria-hidden />
            </button>
          )}
          <ChevronDown className="size-4 text-ink-400" aria-hidden />
        </div>
      </div>

      {open && (
        <ul
          id={`${inputId}-list`}
          role="listbox"
          className="absolute z-50 mt-1 max-h-72 w-full overflow-auto rounded-lg border border-ink-200 bg-white py-1 shadow-lg"
        >
          {matches.length === 0 && (
            <li className="px-3 py-2 text-sm text-ink-500">
              Nothing matches “{query.trim()}”.
            </li>
          )}

          {matches.map((option, index) => (
            <li key={option.id}>
              <button
                type="button"
                role="option"
                aria-selected={option.id === selected}
                className={cn(
                  'flex w-full items-center gap-2 px-3 py-2 text-left text-sm',
                  index === active ? 'bg-brand-50 text-brand-800' : 'text-ink-700 hover:bg-ink-50',
                )}
                // pointerdown would fire before the outside-click handler can
                // see it; mouseenter keeps the highlight and the keyboard in
                // agreement so Enter always picks what is highlighted.
                onMouseEnter={() => setActive(index)}
                onClick={() => choose(option)}
              >
                <Check
                  className={cn('size-3.5 shrink-0', option.id === selected ? 'opacity-100' : 'opacity-0')}
                  aria-hidden
                />
                <span className="truncate">{option.label}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
