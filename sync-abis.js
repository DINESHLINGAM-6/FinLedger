const fs = require('fs');
const path = require('path');

const FOUNDRY_OUT_DIR = path.join(__dirname, 'out');
const FRONTEND_ABI_DIR = path.join(__dirname, 'frontend', 'src', 'abis');

// Create the abis directory if it doesn't exist
if (!fs.existsSync(FRONTEND_ABI_DIR)) {
  fs.mkdirSync(FRONTEND_ABI_DIR, { recursive: true });
}

// Contracts we care about
const contracts = ['MockUSDC', 'InvoiceRegistry', 'FinancingPool'];

contracts.forEach((contract) => {
  const sourcePath = path.join(FOUNDRY_OUT_DIR, `${contract}.sol`, `${contract}.json`);
  const targetPath = path.join(FRONTEND_ABI_DIR, `${contract}.json`);

  if (fs.existsSync(sourcePath)) {
    const fileContent = fs.readFileSync(sourcePath, 'utf8');
    const parsed = JSON.parse(fileContent);
    
    // We only need the ABI, not the entire AST and bytecode!
    const minimalData = {
      abi: parsed.abi,
    };

    fs.writeFileSync(targetPath, JSON.stringify(minimalData, null, 2));
    console.log(`✅ Synced ABI for ${contract}`);
  } else {
    console.warn(`⚠️ Warning: Could not find compiled output for ${contract}. Did you run 'forge build'?`);
  }
});
