import './globals.css';
import { LOGO_URL } from '@/lib/brand';
export const metadata = { title: 'غرف التداول — موقع توصيات', description: 'غرف توصيات خبراء موقع توصيات', icons: { icon: LOGO_URL, apple: LOGO_URL } };
export default function RootLayout({ children }) {
  return (
    <html lang="ar" dir="rtl">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Arabic:wght@400;500;600;700&display=swap" rel="stylesheet" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
      </head>
      <body>{children}</body>
    </html>
  );
}
