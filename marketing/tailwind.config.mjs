/** @type {import('tailwindcss').Config} */
export default {
  content: ['./src/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        brand: {
          // Light mode
          primary:           '#008080',
          'primary-dark':    '#006060',
          'primary-light':   '#4DB8B8',
          'primary-container': '#B2DFDF',
          bg:                '#EEF0F4',
          surface:           '#F0F2F7',
          text:              '#1A1A2E',
          'text-muted':      '#666666',
          border:            '#DDE1EA',
          // Dark mode
          'dark-bg':         '#13131F',
          'dark-surface':    '#1E1E30',
          'dark-surface-hi': '#252540',
          'dark-text':       '#E2E2EE',
          'dark-text-muted': '#9999AA',
          'dark-border':     '#3A3A55',
          'dark-border-sub': '#2A2A42',
          'dark-primary':    '#4DB8B8',
        },
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
      },
    },
  },
  plugins: [],
};
