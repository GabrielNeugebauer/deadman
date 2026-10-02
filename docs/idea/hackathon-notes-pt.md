Mila:
É o Seeker (Solana Mobile), o sucessor do Saga. Em hardware de celular ele é um Android normal. O diferencial está na camada de cripto.

O que tem de diferente de um Android comum

1. Seed Vault (o maior diferencial)
- As chaves privadas ficam num ambiente de hardware isolado, fora do Android e dos apps.
- O app pede a assinatura, o usuário confirma e a chave nunca sai do cofre.
- Na prática, é um hardware wallet embutido no telefone. Num Android comum, a seed fica no software e um malware consegue roubar.

2. dApp Store própria
- Loja de apps de cripto, fora da Google Play.
- A Google e a Apple restringem ou banem apps de cripto. No Seeker, o app vai direto para quem já tem carteira e usa cripto.
- Já passou de 1.200 apps. Checkout aceita USDC, USDT e PYUSD.

3. Seeker Genesis Token
- Um NFT mintado uma vez por aparelho, prova de que o dono tem um Seeker real.
- Dá para fazer airdrop, acesso exclusivo e anti-sybil sem KYC. Num Android comum, isso não existe.

4. Domínio .skr
- Nome legível ligado à carteira, tipo um ENS nativo do ecossistema mobile.

5. Token SKR + economia do aparelho
- SKR é o token do ecossistema: recompensas, staking, acesso e compras in-app.
- Tem trilha de prêmio só de SKR no hackathon.
- O Seeker responde por ~2% do volume de DEX spot da Solana, o que é alto para um aparelho.

6. Solana Mobile Stack (SMS)
- Kit de SDK (Mobile Wallet Adapter, Seed Vault APIs) que qualquer Android pode usar.
- No Seeker a integração é nativa e a UX é bem melhor: conectar a carteira e assinar é quase invisível.

O que NÃO é diferencial: câmera, processador, tela. Não compete com Pixel ou Galaxy no hardware. Compete em ser o iPhone da cripto.

Os dois hackathons ao mesmo tempo

**Prazo**
• World's Fair (Colosseum): 12/out
• CLOCK IN (Seeker): 8/out

**Prêmios**
• World's Fair (Colosseum): $840k + seed
• CLOCK IN (Seeker): $125k USDC + $10k SKR

**O que pedem**
• World's Fair (Colosseum): startup real
• CLOCK IN (Seeker): app mobile sticky

**Entrega**
• World's Fair (Colosseum): pitch + demo
• CLOCK IN (Seeker): APK Android + GitHub + vídeo + deck

**Bônus**
• World's Fair (Colosseum): accelerator $250k
• CLOCK IN (Seeker): featured na dApp Store + call com o Toly

A janela é a mesma. Um time bom entrega um app mobile-first e submete nos dois: no CLOCK IN como app de Seeker e no World's Fair como startup.

O que os jurados do Seeker querem
Stickiness, UX boa, inovação mobile e demo polida. O MONOLITH premiou agentes de IA, games, prediction markets, consumer finance e social mobile.

Ideias que jogam nos dois ao mesmo tempo

O truque é usar o que só o Seeker tem (Seed Vault, Genesis Token, dApp Store, SKR) em cima de uma tese que a Colosseum também premia.

1. Carteira offline / payment channel no Seeker ★★★★★
- Seed Vault assina vouchers offline com segurança de hardware.
- NFC ou Bluetooth de celular para celular, liquidação depois.
- No Seeker: app nativo com UX perfeita.
- No World's Fair: a tese de payment channels + offline.
- Encaixa com eventos, frete e ajuda humanitária.

2. Conta dólar / neobank mobile BR ★★★★★
- Pix na entrada, USDC, yield no Kamino (já tem Earn Vault no Seed Vault Wallet) e saída em Pix.
- Genesis Token = conta verificada sem KYC pesado no começo.
- O Frontier premiou neobank por país (Índia, Filipinas). Ainda não teve versão BR.
- App que a pessoa abre todo dia = stickiness.

3. Prediction market mobile (tipo TikTok de apostas) ★★★★☆
- O MONOLITH já premiou PredictTok e Foresee, então a barra está alta.
- Diferencial: mercados macro BR (Copom, futebol) + resolução com o Seeker como oráculo humano (o Genesis Token prova que é uma pessoa com aparelho real).

4. TCG / cartas no bolso ★★★★☆
- Escanear carta, tokenizar, emprestar, trocar por NFC no torneio.
- Seed Vault guarda o ativo de alto valor. (1/2)

- O Frontier premiou 3 apps de TCG. Falta a versão mobile-first com NFC.

5. Agente de IA no bolso, com teto de gasto ★★★★☆
- O agente vive no Seeker. O Seed Vault assina só dentro de um limite (payment channel).
- SKR paga a inferência (trilha de $10k).
- O MONOLITH já teve SeekerClaw e NOMI. O diferencial é o spending policy no hardware, não o chat.

6. Genesis Token como identidade e anti-sybil ★★★★☆
- "Login com Seeker" para airdrops, governança e crédito.
- Só quem tem o Genesis Token (1 por aparelho) entra.
- Módulo forte dentro de outro produto, fraco sozinho.

7. App de campo offline (gado, frete, carbono) ★★★★☆
- O Seeker no bolso do peão ou do caminhoneiro.
- Assina no Seed Vault sem internet e sincroniza na cidade.
- World's Fair: RWA e public good. Seeker: o único telefone em que isso é seguro de verdade.
- Demo mais difícil de filmar, mas a história é fortíssima.

8. Social pay / divisão de conta / mesada ★★★☆☆
- Transferência por .skr, limites para dependentes e vault familiar.
- Stickiness alta, mas o mercado está mais batido.

Minha recomendação para "ganhar os dois"

Melhor aposta: #1 ou #2.

- #2 (neobank BR) é a mais fácil de demo, a mais sticky e a que os dois júris entendem na hora. Pix → USDC → yield → Pix, no Seed Vault, com Genesis Token.
- #1 (offline + payment channels) é a mais diferenciada e usa o hardware de verdade. Se o time souber NFC e durable nonce, essa é a que o Toly olha e fala "finalmente".

Fórmula do projeto duplo:
1. App Android (React Native ou Kotlin) com Mobile Wallet Adapter + Seed Vault.
2. Um loop diário (pagar, receber, ver saldo, assinar no campo).
3. Integração opcional de SKR (recompensa, acesso ou fee) para pegar o prêmio extra de $10k.
4. Pitch de startup para a Colosseum (mercado, receita, por que Solana).
5. APK na dApp Store para o CLOCK IN.

Prazo prático: CLOCK IN fecha 8/out, World's Fair fecha 12/out. O time trava o APK até o dia 8 e usa os 4 dias seguintes só para polir o pitch da Colosseum.

Se quiser, monto o one-pager de uma dessas duas (neobank BR ou offline/payments) no formato pronto para passar para o time. (2/2)

Mila:
Boa direção. A pegada Seeker + Ledger / multisig offline anti-Drift é exatamente o tipo de ideia que joga nos dois hackathons: no Seeker usa Seed Vault de verdade; no World's Fair resolve o exploit mais caro de 2026.

---

1. O problema do Drift (em uma frase)

Não foi bug de contrato. Foi governança: 2 de 5 signers da multisig assinaram, por engenharia social, transferências admin com durable nonce. Essas assinaturas ficaram válidas para sempre. Semanas depois o atacante executou, tomou o admin e drenou ~$270–285M em minutos.

A Squads já documenta isso como anti-pattern: “using Squads with durable nonces without understanding implications”.

O que falta no mercado: um fluxo de assinatura multi-dispositivo em que:
- a assinatura não fica eternamente válida
- o signer vê o que a tx realmente faz (não um blob)
- admin/governance tem regras diferentes de payment
- offline é seguro, não uma arma

O Sudont (Frontier) fez firewall de execução de agente. Ninguém premiado fez firewall de governança / multisig / durable nonce. Espaço aberto.

---

2. Segurança — ideias

S1. VaultGuard / Anti-Drift Multisig ★★★★★ (a sua intuição)
Seeker + Ledger (ou 2º Seeker) como cosigners de uma Squads/custom vault.

Fluxo:
1. Proposta chega no Seeker (push / NFC / QR).
2. Seed Vault mostra simulação em português: “transfere autoridade X → wallet Y”, “lista mercado Z”, “desliga pause”.
3. Regras onchain (ou no cosigner):
   - admin txs proíbem durable nonce ou exigem expiry curto (ex.: 15 min)
   - valor / tipo de instrução com timelock
   - 2º fator físico: Ledger por cabo/Bluetooth ou 2º Seeker por NFC
4. Scanner de nonces pendentes na vault: alerta se existe tx pré-assinada “zumbi”.
5. Modo offline: assina no avião/cofre; só transmite com 2º device + janela de validade.

Por que ganha nos dois
- Seeker: Seed Vault + UX mobile + NFC entre devices
- World's Fair: resposta direta ao Drift, public good / infra, pitch institucional (tesouraria de protocolo)

MVP 12 dias: wrapper Squads + simulador de ix + policy “no infinite durable nonce on admin” + UI Seeker + cosign Ledger.

Nome de trabalho: NonceGuard, ClearSign Multisig, Two-Key Seeker.

---

S2. ClearSign for Solana (tradutor de transação)
Antes de assinar no Seed Vault, a tela mostra:
- programas tocados
- mudanças de authority / upgrade / freeze
- durable nonce? sim/não + idade do nonce account
- “essa tx ainda funciona daqui a 30 dias?”

Tipo WalletGuard/Blowfish, mas nativo no fluxo Seeker e focado em governance danger, não só swap de memecoin.

Pode ser módulo do S1 ou app standalone. Stickiness: toda vez que assina.

---

S3. Governance Firewall as a Service
Para protocolos:
- registry de admin keys
- monitor de durable nonce accounts ligados a signers
- alerta Telegram/Discord se signer pré-assinou algo fora de policy
- circuit breaker opcional (pause se detectar padrão Drift)

Menos “app fofo” pro CLOCK IN, mais forte no World's Fair (infra/security). Dá para ter companion Seeker pro signer humano.

---

S4. Session keys com teto no Seed Vault
App pede sessão: “pode gastar até $50 em 1h, só Jupiter, sem setAuthority”.
Seed Vault assina session key; master seed não toca DeFi.

Anti-drainer + base para agentes. Sudont é RPC sandbox; isso é policy no hardware. Complementar, não cópia.

---

S5. Herança / dead man's switch / social recovery no Seeker
3 de 5 friends em Seed Vaults; timeout; recovery sem seed em papel.

Consumer sticky. Menos “Drift narrative”, mais retenção no Seeker.

---

S6. Proof of human device for high-risk ops
Operações sensíveis (claim de airdrop admin, bridge grande, multisig) exigem Genesis Token + biometria Seed Vault.

Anti-sybil + anti-malware de PC. Melhor como feature dentro de S1/S4.

---

3. Privacidade — ideias
 (1/3)

Contexto: Confidential Transfers voltaram; Cloak/Umbra/Blackpool já existem; RADR já está no mobile. Privacidade genérica “enviar SOL escondido” está saturada. O gap continua sendo privacidade com compliance e mobile-first.

P1. Folha / tesouraria confidencial no Seeker ★★★★★
- Empresa paga salários com amounts ocultos
- Funcionário vê só o próprio no Seeker
- Contador/auditor tem viewing key (selective disclosure)
- Zcash como patrocinador do World's Fair = gancho de narrativa

Demo: 3 funcionários, 1 auditor, tela do Seeker.

P2. Private pay by NFC / .skr
Aproxima dois Seekers → paga USDC confidencial, recibo local, settle depois.
“Pix privado” entre pessoas. Simples, sticky, bom pro CLOCK IN.

P3. Dark inbox / private portfolio mobile
Saldos e counterparties ocultos no Seed Vault Wallet; share seletivo com contador (liga na ideia fiscal da Nora/Luigi).
Loyal HQ já flertou com private portfolio no Telegram — ângulo Seeker-native ainda fraco.

P4. Private credentials on Seeker
“Provo que sou +18 / investidor qualificado / human Seeker” sem abrir PII.
SAS + Genesis Token + ZK no telefone.
Módulo forte; sozinho é identity genérica (já tentaram muito).

P5. Private agent spend log
Agente gasta via payment channel; log de merchant/valor só o dono lê no Seeker; auditor externo sob pedido.
Cruza agents + privacy + Seeker. Nicho, mas fresco.

P6. Contact discovery privado
Achar amigos onchain sem vazar grafo social (tipo hash/PSI). Social sticky; execução ZK é pesada pro prazo.

---

4. Outros projetos “ganha CLOCK IN + World's Fair”

Além de security/privacy, o que ainda tem cara de double-win:

A
• Ideia: Neobank BR mobile (Pix→USDC→yield→Pix)
• Seeker hook: app diário, Seed Vault, SKR rewards
• World's Fair hook: neobank-por-país ganhou 3x no Frontier
• Risco: compliance/fiat ramp

B
• Ideia: Offline field register (gado/frete/carbono)
• Seeker hook: Seed Vault assina no mato
• World's Fair hook: RWA + “blockchain onde não tem net”
• Risco: demo difícil

C
• Ideia: Group vault / mesada familiar
• Seeker hook: 2 Seekers cosign
• World's Fair hook: consumer finance
• Risco: parece feature

D
• Ideia: Macro PM BR mobile (Copom/futebol)
• Seeker hook: feed tipo TikTok
• World's Fair hook: PM menos lotado
• Risco: PredictTok já no MONOLITH

E
• Ideia: SKR-gated access + real utility
• Seeker hook: trilha $10k SKR
• World's Fair hook: fraco sozinho no WF
• Risco: só SKR = feature

F
• Ideia: Merchant tap-to-pay USDC
• Seeker hook: NFC + dApp Store
• World's Fair hook: payments saturado
• Risco: checkout genérico perde

G
• Ideia: Mobile MM / spread mine lite
• Seeker hook: bot no bolso pro seu perfil de arb
• World's Fair hook: DeFi/gaming mining
• Risco: UX hard, risco

Eu priorizaria, na sua cabeça atual: S1 → P1 ou P2 → A ou B.

---

5. A ideia S1 desdobrada (multisig offline Seeker + Ledger)

Persona: tesoureiro de protocolo, startup com $500k em multisig, family office cripto, DAO signer que viaja.

Promessa: “Nenhuma admin tx no seu vault pode ser pré-assinada para sempre. Todo cosign é claro, com prazo, e exige dois mundos (mobile SE + cold Ledger).”

Arquitetura em camadas:
1. Policy program (ou config Squads + guard): classifica ix (transfer normal vs setAuthority vs upgrade).
2. Nonce policy: payment ok com durable nonce de curta validade; admin = blockhash recente ou nonce com hard expiry onchain.
3. ClearSign engine: simula e humaniza.
4. Seeker app: fila de propostas, biometria, Seed Vault.
5. Ledger cosign: 2º fator para threshold.
6. Watchdog: indexa nonce accounts dos signers; dashboard + alerta.

Por que não é só “Squads no mobile”: Squads não resolve sozinho o social eng de pré-assinatura eterna + UX de perigo. O produto é a política + clareza + hardware path.

Demo de 90 segundos (jurados amam):
1. Atacante manda “atualização de oracle” que na verdade é setAuthority. (2/3)

2. Android comum / extension: usuário quase assina.
3. Seeker: tela vermelha “ADMIN · CHANGE AUTHORITY · DURABLE NONCE VÁLIDO 999 DIAS”.
4. Bloqueia; pede Ledger + timelock 24h.
5. Mostra dashboard: “2 nonces zumbis revogados”.

Receita (World's Fair): SaaS por vault ($/mês) + fee em high-value cosign + white-label para custodians.

SKR track: stake SKR → limites maiores de vault monitorado, ou fee discount.

---

6. Privacidade desdobrada no mesmo espírito

Se security é “não assinar o errado”, privacy é “não vazar o certo”.

Combo forte Seeker:  
P2 (NFC private pay) como consumer wedge + P1 (payroll viewing key) como B2B pitch no World's Fair.  
Um APK, duas histórias.

Combo security + privacy:  
Multisig em que os signers veem a tx, mas o mundo externo não vê amounts de treasury moves (confidential + clear internal simulation). Avançado demais pro MVP, mas bom no deck como roadmap.

---

7. O que eu não faria agora

- Outro audit.ai / fuzz de contrato (lotado, Cypherpunk já premiou)
- Outro “Cloak clone” só de transfer privado
- Outro agent chat com wallet (MONOLITH já lotou)
- Checkout Amazon/stablecoin genérico (Sp3nd etc.)
- Copiar Sudont (já ganhou Frontier)

---

8. Ranking pra você decidir

Prioridade  Produto                         CLOCK IN   World's Fair   Usa Seeker de vdd
1           Anti-Drift multisig S+Ledger    ★★★★☆      ★★★★★          Seed Vault+NFC+cosign
2           ClearSign + nonce watchdog      ★★★★☆      ★★★★☆          toda assinatura
3           Private pay NFC / payroll       ★★★★★      ★★★★☆          mobile-first
4           Session keys anti-drainer       ★★★★☆      ★★★☆☆          Seed Vault policy
5           Neobank BR                      ★★★★★      ★★★★☆          sticky diário
6           Offline field (gado/frete)      ★★★☆☆      ★★★★★          offline+Vault


A #1 é a que mais conversa com o que você falou (offline + Seeker + Ledger + Drift). A #3 é a mais “app que a pessoa usa”. A #5 é a mais óbvia de consumer se security parecer “só pra protocolo”.

---

Se quiser no próximo passo, eu fecho um one-pager só da #1 (Anti-Drift Multisig) com: user flow, stack (Squads ou custom), escopo MVP 8/out e 12/out, o que fica pro roadmap, e como fatiar o pitch CLOCK IN vs Colosseum. Ou faço o mesmo da #3 privacidade. Qual das duas? (3/3)