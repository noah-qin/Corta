import { asset } from "@/lib/site";
import { notFound } from "next/navigation";
import { languages } from "@/lib/i18n";
import "../globals.css";
export function generateStaticParams() {
  return languages.map((l) => ({ lang: l.code }));
}
export const dynamicParams = false;
export const metadata = { icons: { icon: asset("corta-pangolin-mascot.png") } };
export default async function Layout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ lang: string }>;
}) {
  const { lang } = await params;
  if (!languages.some((l) => l.code === lang)) notFound();
  return (
    <html lang={lang}>
      <body>{children}</body>
    </html>
  );
}
