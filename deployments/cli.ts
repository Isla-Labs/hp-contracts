import { parseArgs } from "node:util";
import { readdir } from "node:fs/promises";

type ChainDetails = {
  name: string;
  explorerUrl: string;
  isTestnet: boolean;
};

const GITHUB_REPO = process.env.GITHUB_REPO ?? "Isla-Labs/hp-v1-contracts";

const chains: { [chainId: number]: ChainDetails } = {
  8453: {
    name: "Base",
    explorerUrl: "https://basescan.org",
    isTestnet: false,
  },
  84532: {
    name: "Base Sepolia",
    explorerUrl: "https://sepolia.basescan.org",
    isTestnet: true,
  },
};

type Transaction = {
  hash: `0x${string}`;
  contractName: string;
  transactionType: "CREATE" | "CREATE2" | "CALL";
  contractAddress: `0x${string}`;
  arguments: `0x${string}`[];
};

type Broadcast = {
  transactions: Transaction[];
  commit: string;
  chain: number;
  timestamp: number;
};

type Deployment = {
  contractName: string;
  contractAddress: `0x${string}`;
  hash: `0x${string}`;
  arguments: `0x${string}`[];
  commit: string;
  timestamp: number;
};

function shorten(a: string, length: number = 4): string {
  return `${a.slice(0, length + 2)}...${a.slice(-length)}`;
}

function convertTimestamp(timestamp: number): string {
  return new Date(
    new Date(timestamp).getFullYear() === 1970 ? timestamp * 1000 : timestamp,
  ).toUTCString();
}

function generateTable(deployments: Deployment[], chainId: string): string {
  const chain = chains[Number(chainId)];
  if (!chain) return "";
  const explorerUrl = chain.explorerUrl;

  let content = `| Contract | Address | Transaction | Commit |\n`;
  content += "|---|---|---|---|\n";

  deployments.forEach((d) => {
    content += `| ${d.contractName}`;
    content += ` | [${shorten(d.contractAddress)}](${explorerUrl}/address/${d.contractAddress})`;
    content += ` | [${shorten(d.hash, 4)}](${explorerUrl}/tx/${d.hash})`;
    content += ` | [${d.commit}](https://github.com/${GITHUB_REPO}/commit/${d.commit})`;
    content += ` | \n`;
  });

  return content;
}

function getLatestDeployments(deployments: Deployment[]): Deployment[] {
  const latestDeployments: { [key: string]: Deployment } = {};

  deployments.forEach((deployment) => {
    if (!latestDeployments[deployment.contractName]) {
      latestDeployments[deployment.contractName] = deployment;
    } else if (latestDeployments[deployment.contractName].timestamp < deployment.timestamp) {
      latestDeployments[deployment.contractName] = deployment;
    }
  });

  return Object.values(latestDeployments);
}

async function generateHistoryLogs(): Promise<void> {
  const broadcastFiles = await readdir("./broadcast", { recursive: true }).catch(() => [] as string[]);

  const jsonFiles = broadcastFiles.filter(
    (file) => file.endsWith(".json") && !file.includes("dry") && !file.includes("latest"),
  );

  const deployments: { [chainId: string]: Deployment[] } = {};

  for (const file of jsonFiles) {
    const filePath = `./broadcast/${file}`;
    const raw = Bun.file(filePath);
    const broadcast: Broadcast = await raw.json();

    if (broadcast.chain === 31337) continue;

    if (deployments[broadcast.chain] === undefined) {
      deployments[broadcast.chain] = [];
    }

    const transactions = broadcast.transactions
      .filter(
        (transaction) =>
          (transaction.transactionType === "CREATE" || transaction.transactionType === "CREATE2") &&
          transaction.hash !== null &&
          transaction.contractName !== null,
      )
      .map((transaction) => ({
        contractName: transaction.contractName,
        contractAddress: transaction.contractAddress,
        hash: transaction.hash,
        arguments: transaction.arguments,
        commit: broadcast.commit as `0x${string}`,
        timestamp: broadcast.timestamp,
      }));

    deployments[broadcast.chain].push(...transactions);
  }

  for (const chainId in deployments) {
    if (deployments[chainId].length === 0 || !chains[Number(chainId)]) continue;

    let content = `# Deployments on ${chains[Number(chainId)].name} (${chainId})\n`;
    const timestamps: { [key: number]: Deployment[] } = {};

    deployments[chainId].forEach((d) => {
      if (!timestamps[d.timestamp]) timestamps[d.timestamp] = [];
      timestamps[d.timestamp].push(d);
    });

    for (let i = Object.values(timestamps).length - 1; i >= 0; i--) {
      const t = Object.values(timestamps)[i];
      content += `### ${convertTimestamp(t[0].timestamp)}\n`;
      content += generateTable(t, chainId);
    }

    await Bun.write(`deployments/${chainId}.md`, content);
  }

  const mainnetLabels: string[] = [];
  let mainnetDeployments = "## Mainnet Deployments\n";

  for (const chainId in deployments) {
    const chain = chains[Number(chainId)];
    if (deployments[chainId].length === 0 || !chain || chain.isTestnet) continue;

    deployments[chainId].sort((a, b) => a.contractName.localeCompare(b.contractName));
    const latestDeployments = getLatestDeployments(deployments[chainId]);
    mainnetDeployments += `### ${chain.name} (${chainId})\n`;
    mainnetDeployments += generateTable(latestDeployments, chainId);
    mainnetLabels.push(chain.name);
  }

  const testnetLabels: string[] = [];
  let testnetDeployments = "## Testnet Deployments\n";

  for (const chainId in deployments) {
    const chain = chains[Number(chainId)];
    if (deployments[chainId].length === 0 || !chain || !chain.isTestnet) continue;

    deployments[chainId].sort((a, b) => a.contractName.localeCompare(b.contractName));
    const latestDeployments = getLatestDeployments(deployments[chainId]);
    testnetDeployments += `### ${chain.name} (${chainId})\n`;
    testnetDeployments += generateTable(latestDeployments, chainId);
    testnetLabels.push(chain.name);
  }

  await Bun.write(
    "./Deployments.md",
    generateDeploymentsFile(mainnetLabels, mainnetDeployments, testnetLabels, testnetDeployments),
  );
}

function generateDeploymentsFile(
  mainnetLabels: string[],
  mainnets: string,
  testnetLabels: string[],
  testnets: string,
): string {
  return `# Contract Addresses

Networks that HighPotential is deployed to:

- Mainnets: ${mainnetLabels.join(", ") || "None"}
- Testnets: ${testnetLabels.join(", ") || "None"}

${mainnets}
${testnets}
`;
}

async function main() {
  const { values } = parseArgs({
    args: Bun.argv,
    options: {
      output: { type: "string" },
    },
    strict: true,
    allowPositionals: true,
  });

  switch (values.output) {
    case "history":
      await generateHistoryLogs();
      break;
    default:
      console.error(`Unknown command: ${values.output}`);
      process.exit(1);
  }
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
