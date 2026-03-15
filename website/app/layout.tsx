import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'HyperPointer — Point at anything. Ask Claude.',
  description: 'HyperPointer adds a floating AI panel to your cursor. Point at anything on your Mac, press Ctrl+Space, and ask Claude about it.',
  openGraph: {
    title: 'HyperPointer',
    description: 'Point at anything on your screen. Ask Claude about it.',
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
