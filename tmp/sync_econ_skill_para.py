anchor = 'slots and publishes resource extraction through `extra_change`.'
add = '''On the worker path (`capture_worker_day_input`) the economy owns its reserves: slots seed the
worker float lanes once (or the saved stock on restore), extraction folds into them at publish,
and natural regeneration runs at each capture through the shared `natural_resource_kernel.h`
with knobs from `configure_economy_natural_resources`. The main-thread natural pass then skips
those resources and `flush_runtime_economy_resource_writeback` only mirrors worker values back to
the slots. Never re-seed from slots on the worker: their content lags by a machine-speed
dependent number of days.'''
for d in ['.codex', '.agents', '.claude', '.codebuddy', '.dsh']:
    p = d + '/skills/project-keynes-economy-runtime/references/architecture-and-data.md'
    raw = open(p, 'rb').read().decode('utf-8')
    nl = '\r\n' if '\r\n' in raw else '\n'
    if 'natural_resource_kernel.h' in raw:
        print(d, 'already')
        continue
    assert raw.count(anchor) == 1, d
    raw = raw.replace(anchor, anchor + nl + add.replace('\n', nl))
    open(p, 'wb').write(raw.encode('utf-8'))
    print(d, 'ok')
