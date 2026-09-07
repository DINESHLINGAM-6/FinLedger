"use client";

import * as React from "react";
import {
  RainbowKitProvider,
  getDefaultConfig,
  darkTheme,
} from "@rainbow-me/rainbowkit";
import { WagmiProvider } from "wagmi";
import { foundry } from "wagmi/chains";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import "@rainbow-me/rainbowkit/styles.css";

// 1. Configure Wagmi to use our local Foundry chain (Anvil)
const config = getDefaultConfig({
  appName: "FinLedger",
  projectId: "finledger-local-dev", // Project ID is required but can be anything for localhost
  chains: [foundry],
  ssr: true, // Server-Side Rendering support
});

const queryClient = new QueryClient();

// 2. Wrap our app in the necessary providers
export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={darkTheme()}>
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
