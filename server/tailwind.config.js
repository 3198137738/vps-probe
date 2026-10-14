// 前端样式编译配置，用法见 README「修改前端」
module.exports = {
  content: [process.env.SRC],
  darkMode: 'class',
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', '-apple-system', 'BlinkMacSystemFont', 'PingFang SC', 'Microsoft YaHei', 'sans-serif'],
        mono: ['JetBrains Mono', 'ui-monospace', 'SFMono-Regular', 'Menlo', 'Consolas', 'monospace'],
      },
      colors: {
        canvas: { light: '#f8fafc', dark: '#0b0f17' }
      }
    }
  }
}
