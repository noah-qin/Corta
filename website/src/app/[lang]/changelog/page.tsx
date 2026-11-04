import { Document } from "@/components/document";
import { metadata as makeMetadata } from "@/lib/site";
export async function generateMetadata({
  params,
}: {
  params: Promise<{ lang: string }>;
}) {
  const { lang } = await params;
  return makeMetadata(lang, "changelog");
}
export default async function Page({
  params,
}: {
  params: Promise<{ lang: string }>;
}) {
  const { lang } = await params;
  return <Document lang={lang} slug="changelog" />;
}
