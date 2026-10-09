import { defineConfig } from 'vite';
import path from 'path';

export default defineConfig({
  publicDir: false,
  build: {
    outDir: path.resolve(__dirname, 'dist'),
    emptyOutDir: true,
    lib: { entry: path.resolve(__dirname, 'index.ts'), formats: ['es'], fileName: () => 'volai-web-sdk.js' },
    sourcemap: true,
    target: 'es2020',
  },
});
