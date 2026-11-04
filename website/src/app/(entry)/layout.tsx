import { asset } from "@/lib/site";
import "../globals.css";
export const metadata = { icons: { icon: asset("corta-pangolin-mascot.png") } };
export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
