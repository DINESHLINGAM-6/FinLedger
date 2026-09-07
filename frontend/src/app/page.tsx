import { ConnectButton } from '@rainbow-me/rainbowkit';

export default function Page() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center p-24 bg-zinc-950 text-white">
      <div className="z-10 w-full max-w-5xl items-center justify-between font-mono text-sm flex">
        <p className="fixed left-0 top-0 flex w-full justify-center border-b border-zinc-800 bg-zinc-900/50 pb-6 pt-8 backdrop-blur-2xl lg:static lg:w-auto  lg:rounded-xl lg:border lg:p-4">
          FinLedger &nbsp;
          <code className="font-mono font-bold text-blue-400">v1.0</code>
        </p>
        <div className="fixed bottom-0 left-0 flex h-48 w-full items-end justify-center bg-gradient-to-t from-black via-black lg:static lg:h-auto lg:w-auto lg:bg-none">
          <div className="pointer-events-auto">
            <ConnectButton />
          </div>
        </div>
      </div>

      <div className="mt-32 text-center">
        <h1 className="text-6xl font-bold tracking-tight mb-8">
          Tokenized <span className="text-blue-500">Invoice Financing</span>
        </h1>
        <p className="text-xl text-zinc-400 max-w-2xl mx-auto">
          Submit your invoices, get them verified, and receive instant liquidity from investors.
        </p>
      </div>
    </main>
  );
}
