// Disk panel for the conversation dock.
//
// Rendering is React inside a host slot, so it inherits the page theme: every
// colour below is derived from `currentColor` with color-mix, which means the
// same component reads correctly in light and dark without knowing token
// names. The data comes from the local helper's read-only endpoint.
window.__ModuleLoader__.load({
  id: '@local/sweep-panel',
  factory(require) {
    const React = require('react');
    const h = React.createElement;

    const ENDPOINT = 'http://127.0.0.1:47901/status';
    const POLL_MS = 3000;

    function bytes(value) {
      if (!value) return '0 B';
      const units = ['B', 'KB', 'MB', 'GB', 'TB'];
      let index = 0;
      let size = value;
      while (size >= 1024 && index < units.length - 1) {
        size /= 1024;
        index += 1;
      }
      return (size >= 100 || index === 0 ? Math.round(size) : size.toFixed(1)) + ' ' + units[index];
    }

    const style = {
      card: {
        margin: '4px 0 8px',
        padding: '10px 12px',
        borderRadius: '10px',
        border: '1px solid color-mix(in srgb, currentColor 14%, transparent)',
        background: 'color-mix(in srgb, currentColor 4%, transparent)',
        display: 'flex',
        flexDirection: 'column',
        gap: '7px',
        fontSize: '12px',
        lineHeight: 1.5,
        color: 'inherit',
      },
      row: {
        display: 'flex',
        alignItems: 'baseline',
        justifyContent: 'space-between',
        gap: '12px',
      },
      title: { fontWeight: 600, fontSize: '13px' },
      muted: { opacity: 0.62 },
      track: {
        height: '4px',
        borderRadius: '2px',
        background: 'color-mix(in srgb, currentColor 12%, transparent)',
        overflow: 'hidden',
      },
      fill: {
        height: '100%',
        borderRadius: '2px',
        background: 'color-mix(in srgb, currentColor 52%, transparent)',
      },
      grid: {
        display: 'grid',
        gridTemplateColumns: 'minmax(84px, auto) 1fr auto',
        gap: '2px 10px',
        alignItems: 'center',
      },
      warn: {
        opacity: 0.72,
        fontSize: '11px',
      },
    };

    function Bar({ value, max }) {
      const fraction = max > 0 ? Math.max(0.02, Math.min(1, value / max)) : 0;
      return h('div', { style: style.track }, h('div', { style: { ...style.fill, width: (fraction * 100).toFixed(1) + '%' } }));
    }

    function Panel() {
      const [status, setStatus] = React.useState(null);
      const [failing, setFailing] = React.useState(false);

      React.useEffect(() => {
        let alive = true;
        const load = () => {
          fetch(ENDPOINT, { cache: 'no-store' })
            .then((response) => (response.ok ? response.json() : null))
            .then((json) => {
              if (alive) {
                setStatus(json);
                setFailing(false);
              }
            })
            .catch(() => {
              if (alive) {
                setStatus(null);
                setFailing(true);
              }
            });
        };
        load();
        const timer = setInterval(load, POLL_MS);
        return () => {
          alive = false;
          clearInterval(timer);
        };
      }, []);

      if (!status || !status.disk) {
        return failing
          ? h('div', { style: { ...style.card, ...style.muted } }, 'sweep helper 未连接 · 运行 sweep helper-install')
          : null;
      }

      const { disk, latest, mode, fullDiskAccess } = status;
      const usedPercent = disk.totalBytes > 0 ? (disk.usedBytes / disk.totalBytes) * 100 : 0;
      const groups = (latest && latest.groups ? latest.groups : []).slice(0, 4);
      const maxBytes = groups.reduce((max, group) => Math.max(max, group.bytes), 0);
      const total = groups.reduce((sum, group) => sum + group.bytes, 0);

      return h(
        'div',
        { style: style.card },
        h(
          'div',
          { style: style.row },
          h('span', { style: style.title }, '磁盘 ' + bytes(disk.availableBytes) + ' 可用'),
          h('span', { style: style.muted }, usedPercent.toFixed(0) + '% 已用'),
        ),
        h(
          'div',
          { style: style.track },
          h('div', { style: { ...style.fill, width: usedPercent.toFixed(1) + '%' } }),
        ),
        latest && groups.length > 0
          ? h(
              'div',
              { style: style.grid },
              ...groups.flatMap((group) => [
                h('span', { key: group.category + '-label', style: style.muted }, group.label),
                h(Bar, { key: group.category + '-bar', value: group.bytes, max: maxBytes }),
                h('span', { key: group.category + '-bytes' }, bytes(group.bytes)),
              ]),
            )
          : h('div', { style: style.muted }, '还没有扫描结果，让 agent 扫一次就会出现在这里。'),
        h(
          'div',
          { style: style.row },
          h('span', { style: style.muted }, latest ? '最近扫描 ' + bytes(total) + ' · ' + mode : '模式 ' + mode),
          !fullDiskAccess ? h('span', { style: style.warn }, '缺完全磁盘访问权限') : null,
        ),
      );
    }

    return {
      inject: ['slots'],
      apply(ctx) {
        ctx.slots.inject('conversation.composer.dock', () =>
          ctx.slots.register(
            { name: 'conversation.composer.dock', id: 'sweep-panel', order: 5 },
            Panel,
          ),
        );
      },
    };
  },
});
