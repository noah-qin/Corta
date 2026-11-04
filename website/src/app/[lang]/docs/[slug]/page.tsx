import { Document } from "@/components/document";
import { manifest, metadata as makeMetadata } from "@/lib/site";
export function generateStaticParams() {
  return manifest.documents
    .filter((d) => d.slug !== "changelog")
    .map((d) => ({ slug: d.slug }));
}
export const dynamicParams = false;
export async function generateMetadata({
  params,
}: {
  params: Promise<{ lang: string; slug: string }>;
}) {
  const { lang, slug } = await params;
  return makeMetadata(lang, slug);
}
export default async function Page({
  params,
}: {
  params: Promise<{ lang: string; slug: string }>;
}) {
  return <Document {...(await params)} />;
}
