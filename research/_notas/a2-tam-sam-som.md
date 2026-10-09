# A2 — Checagem dos itens (6) a (9) e recálculo de TAM/SAM/SOM

Data de acesso de todas as fontes: 2026-10-07. Convenções:

- **FATO VERIFICADO** = número lido na fonte citada (URL na tabela no fim).
- **ESTIMATIVA** = premissa ou cálculo meu; não é dado de fonte.
- Confiança: **alta** (fonte primária ou dado on-chain/oficial), **média** (imprensa especializada citando a fonte primária), **baixa** (fonte secundária sem link primário, ou que eu não consegui abrir).

---

## 1. Checagem dos números do deck

### (6) TAM: "33,9M endereços ativos mensais na Solana × US$480/ano = US$16B (Token Terminal 2026)"

**FATO VERIFICADO**

- Investing.com (Milko Trajcevski, 09/04/2026): "Token Terminal data shows that Solana currently records around 34 million monthly active addresses. This is a dip from the March active address count of 40 million." Confiança: **média** (imprensa citando Token Terminal; não consegui abrir o painel do Token Terminal, que só renderiza via JS).
- O número "33,9M em abril/2026" aparece em Solana Compass (23/08/2026), citando o Investing.com e o Token Terminal. Confiança: **média**.
- Token Terminal define usuários ativos como "unique addresses that use the protocol's service" (FAQ de métricas, 31/01/2023). Ou seja, mede **endereços**, não pessoas. Confiança: **alta**.
- Os outros painéis dão valores bem diferentes para a mesma métrica:
  - The Block Data, "Number of Active Addresses on the Solana Network (Monthly)": 47.292.047, último ponto em 05/10/2026. Confiança: **média** (lido do feed de dados da página; não confirmei a qual mês fechado o ponto se refere).
  - Artemis, via TechFlow (17/12/2025): "approximately 98 million MAU". Confiança: **baixa/média**.
  - The Block (04/11/2024): recorde de "over 123 million" endereços ativos em out/2024. Confiança: **média**.
  - Cointelegraph (09/10/2024), com dados da Artemis e da Hello Moon: ~100M de endereços ativos mensais, dos quais "86 million users held 0 SOL". Confiança: **média**.
- Endereços que guardam SOL: 8,38M na última semana de set/2026; carteiras com stablecoin: 13,07M. Fonte: Solana Ecosystem Roundup set/2026, publicado em solana.com. Confiança: **alta** (oficial).

**Problemas**

1. O slide diz "Monthly active users", mas o número é de **endereços**. Uma pessoa controla várias carteiras, e bots, exchanges e contas de programa inflam a contagem. Em out/2024, 86% dos ~100M endereços ativos tinham 0 SOL.
2. A métrica oscila muito: 123M (out/24), ~98M (dez/25), 40M (mar/26), ~34M (abr/26), ~47M (último ponto na The Block). Ela serve para mostrar atividade, não como base de clientes.
3. O rótulo "Token Terminal 2026" deveria dizer **"Token Terminal, abr/2026 (via Investing.com)"**.
4. A conta 33,9M × 480 = US$16,27B está aritmeticamente certa, mas a metodologia está errada (ver seção 2).

**Veredito:** o número existe (~34M, abr/2026), mas são endereços, e não "usuários". **Não usar como TAM de pessoas.**

### (7) SAM: "15M usuários da Phantom × US$480/ano = US$7,2B (Phantom 2025)"

**FATO VERIFICADO**

- The Block (16/01/2025): "The company said it has 15 million monthly active users and $25 billion in self-custody assets." Esses dados vêm do anúncio da Série C (US$150M a US$3B de valuation). O Cointelegraph (17/01/2025) dá o mesmo número. Confiança: **média/alta**. É o que a empresa declarou; ninguém auditou.
- Fortune Crypto 100 (2026): "more than 15 million monthly active users", "roughly $25 billion". Confiança: **média**.
- A CoinLaw (atualizada em 29/09/2026) atribui a Brandon Millman, no keynote do Solana Accelerate 2025, a frase "almost 17 million monthly active users at its peak". Confiança: **baixa** (secundária, não vi o vídeo). Outros agregadores falam em "~20M", sem fonte primária localizável. Confiança: **baixa**, não usar.
- O blog da Phantom sobre a Série C não foi encontrado (o URL testado deu 404).

**Problemas**

1. 15M é **MAU** (usuário ativo no mês), não total de usuários. O número está certo nesse sentido, mas é de **jan/2025**, não "2025" em geral.
2. A Phantom é **multichain** (Solana, Ethereum, Base, Bitcoin, Sui, Polygon etc.), então nem todo MAU dela é usuário de Solana. Em compensação, o número exclui Solflare, Backpack, Jupiter e Seed Vault. Como aproximação de "pessoas em autocustódia na Solana", 15M é razoável, mas é um **proxy**.
3. O SAM do deck soma iOS, extensão de navegador e desktop. O Deadman é mobile, só no Seeker até meados de 2027 e só Android depois. Nada disso é mercado alcançável hoje.
4. Novamente, ×US$480 supõe que 100% pagam o plano mensal cheio.

**Veredito:** 15M MAU (jan/2025) está verificado. Usar como **TAM de pessoas** (proxy), não como SAM. Rótulo: "Phantom, jan/2025".

### (8) SOM: "150K donos de Seeker × US$480/ano = US$72M (Solana Mobile 2025)"

**FATO VERIFICADO**

| Número              | O que é                                                                                        | Data                                                | Fonte                                                                                                                                        | Confiança                                         |
| ------------------- | ---------------------------------------------------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| 140.000+            | **pré-vendas** em 57 países                                                                    | 18/09/2024                                          | The Block (citando Solana Mobile)                                                                                                            | média                                             |
| 150.000+            | **pré-vendas** ("reserved"/"pre-ordered") no início dos envios                                 | 04-06/08/2025                                       | CoinDesk, MobileIDWorld, The Block                                                                                                           | média                                             |
| "tens of thousands" | unidades **em envio** em ago/2025                                                              | ago/2025 (citado em 03/12/2025)                     | The Block                                                                                                                                    | média                                             |
| **100.908**         | usuários que receberam o airdrop de SKR (exige o Seeker Genesis Token ativado, 1 por aparelho) | jan/2026                                            | CoinMarketCap Academy ("1,819,755,000 SKR to 100,908 users"); a The Block (20/01/2026) cita a Solana Mobile: "over 100,000 of you can claim" | **alta/média** (melhor proxy de aparelhos ativos) |
| 175.000+            | "sold" (vendidos)                                                                              | sem data; perfil de expositor do MWC Barcelona 2027 | texto da própria Solana Mobile no site do MWC                                                                                                | baixa/média (autodeclarado, sem data)             |
| 200.000+            | "shipped" (enviados)                                                                           | fev/2026                                            | post no X @solanamobile/2023770158645342255; só vi o resumo do buscador, a página deu 402                                                    | **baixa**                                         |
| 9.000+              | usuários ativos **diários** na Season 2                                                        | jun/2026                                            | SolanaFloor, recap de junho da Solana Mobile                                                                                                 | média                                             |

- Verificação on-chain: o Seeker Genesis Token é um mint Token-2022 com grupo/metadata `GT22s89nU4iWFkNXj1Bw6uYhJJWDRPpShHt4Bk8f99Te` (docs.solanamobile.com). Tentei contar os mints pela DAS da Helius, mas a chave de API do MCP está inválida (401). **Não verificado on-chain.** Para fechar o número, rodar `getAssetsByGroup` ou contar mints Token-2022 com o TokenGroupMember = GT22s… usando uma chave válida.

**Problemas**

1. "150K donos" está **errado como rótulo**: são **pré-vendas** de ago/2025. O dado verificável mais forte de aparelhos ativos é **~101K** (airdrop SKR, jan/2026). Os números maiores (175K vendidos, 200K enviados) são autodeclarados, sem data clara ou sem acesso.
2. Rótulo correto: "~100K Seekers ativados (airdrop SKR, jan/2026)". Se o time quiser mostrar o teto, pode acrescentar "175K+ vendidos (Solana Mobile)".
3. Chamar de SOM o equivalente a 100% dos donos pagando US$480/ano é o maior erro do slide. SOM é a fatia que dá para **capturar** em 2–3 anos.

### (9) "Taxa base da Solana ~0,000005 SOL (5.000 lamports) por transação"

**FATO VERIFICADO** (docs oficiais, solana.com/docs/core/fees): taxa base de **5.000 lamports por assinatura**, metade queimada e metade para o validador. A taxa de prioridade é à parte: `ceil(compute_unit_price × compute_unit_limit / 1.000.000)` lamports, 100% para o validador. Confiança: **alta**.

**Ajuste:** a taxa é **por assinatura**, não por transação. Um check-in patrocinado pela Kora costuma ter 2 assinaturas (fee payer da Kora + usuário), o que dá **10.000 lamports** (0,00001 SOL) mais a taxa de prioridade, se houver.

- ESTIMATIVA de custo para o Deadman: check-in semanal = 52 × 10.000 = 520.000 lamports ≈ **0,00052 SOL/usuário/ano**. Check-in diário = 3.650.000 lamports ≈ 0,00365 SOL/ano. Não inclui rent nem prioridade. O custo de patrocínio é desprezível frente a qualquer ARPU.
- Texto sugerido para o deck: "~0,000005 SOL por assinatura (5.000 lamports)".

---

## 2. Erros de metodologia do slide de mercado

1. **Endereço ≠ pessoa** (TAM). Ver item (6).
2. **×US$480 supõe 100% de conversão no plano mais caro.** Para TAM, a premissa de 100% de adoção é aceitável por definição, mas o ARPU precisa ser o **médio realista**, e não o do plano premium. Para SOM, a premissa de 100% é simplesmente inválida.
   - Benchmark de conversão (RevenueCat, State of Subscription Apps 2026, publicado em 19/03/2026): download→pago no D35 com mediana de **2,1% em freemium** e **10,7% com hard paywall**. Cerca de 72% dos assinantes anuais cancelam no 1º ano. Confiança: **alta** (relatório primário, mas de apps de consumo em geral, não de cripto).
3. **O plano de US$40/mês é irracional para a maioria dos usuários**, porque compete com a taxa de 0,5% cobrada uma única vez:
   - O plano compensa só quando 0,005 × V > 480 × T, ou seja, **V > US$96.000 × T** (T = anos de assinatura até a liberação/cancelamento). Pagando em SKR (US$420/ano): V > US$84.000 × T.
   - Valor médio por usuário da Phantom: US$25B / 15M ≈ **US$1.667** (média, puxada por baleias; a mediana deve ser bem menor). ESTIMATIVA derivada de dado verificado.
   - Conclusão: só "baleias" (> ~US$100K–300K no cofre) assinam. A maior parte da receita vem da taxa, que é **pontual e atrasada**: só entra na execução ou no cancelamento.
4. **Comparação de preço** (FATO VERIFICADO, páginas de preço em 07/10/2026):
   - Cipherwill Premium: **US$40/ano** (preço cheio US$60, com 30% off). O plano do Deadman custa **12×** isso.
   - Casa Standard: **US$250/ano**, com herança incluída. Premium: US$2.100/ano. Private Client: US$7.500/ano. O plano do Deadman custa ~1,9× o Casa Standard.
5. **SAM fora do alcance real.** O produto só roda no Seeker até meados de 2027 e só em Android depois. A base Phantom inclui iOS, extensão de navegador e outras chains.
6. **Datas e rótulos.** "Phantom 2025" é jan/2025. "Solana Mobile 2025" se refere a pré-vendas de ago/2025. "Token Terminal 2026" é abr/2026, via imprensa.

---

## 3. ARPU misto (assinantes + taxa de 0,5%)

Fórmula (ESTIMATIVA), por usuário por ano:

ARPU = s × P_sub + (1 − s) × 0,005 × V / L

- s = fração de assinantes (só baleias, pelo break-even acima)
- P_sub = US$450/ano (mistura de US$480 em USD e US$420 em SKR)
- V = valor médio no cofre de quem paga a taxa
- L = vida média do cofre até a execução ou o cancelamento, em anos. A taxa é cobrada uma vez e anualizada aqui.

| Cenário                             | s     | V                          | L   | Assinatura | Taxa  | **ARPU**   |
| ----------------------------------- | ----- | -------------------------- | --- | ---------- | ----- | ---------- |
| Conservador                         | 0,25% | US$1.000                   | 3   | 1,13       | 1,66  | **US$2,8** |
| Base                                | 0,5%  | US$1.700 (≈ média Phantom) | 2   | 2,25       | 4,23  | **US$6,5** |
| Otimista                            | 1%    | US$5.000                   | 2   | 4,50       | 12,38 | **US$17**  |
| Seeker (público mais cripto-nativo) | 2%    | US$5.000                   | 2   | 9,00       | 12,25 | **US$21**  |

Checagem cruzada pelo valor: se 100% dos US$25B da Phantom fossem para cofres, a receita da taxa seria 0,005 × 25B / 2 ≈ US$62,5M/ano. Com o ARPU base, 15M × US$6,5 ≈ US$97,5M/ano. A ordem de grandeza bate (dezenas a ~100 milhões, não bilhões).

Risco: se L for longo (o usuário mantém o cofre até morrer), a receita da taxa anualizada cai muito. Isso fortalece o argumento a favor de uma assinatura mais barata, de US$3–5/mês, ou de uma taxa anual pequena sobre o valor protegido. **Decisão de preço do time, não verificada.**

---

## 4. Recálculo TOP-DOWN (ESTIMATIVA sobre dados verificados)

| Camada                                                  | Base (FATO)                                      | Filtro (premissa)                                                                   | Pessoas | ARPU            | **Receita/ano** (faixa) |
| ------------------------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------- | ------- | --------------- | ----------------------- |
| **TAM**: autocustódia no ecossistema Solana             | 15M MAU Phantom (jan/2025), proxy de pessoas     | 100% (definição de TAM)                                                             | 15M     | US$6,5 (2,8–17) | **~US$100M** (42–255M)  |
| **SAM**: Android/mobile, alcançável após meados de 2027 | 15M                                              | × 69,17% Android (StatCounter, set/2026; supõe o mix global de SO)                  | ~10,4M  | US$6,5          | **~US$67M** (29–177M)   |
| **SAM até meados de 2027**: só Seeker                   | ~100,9K Seekers ativados (airdrop SKR, jan/2026) | 100%                                                                                | ~101K   | US$21           | ~US$2,1M                |
| **SOM**: 24 meses                                       | ~100,9K Seekers                                  | 5% de captura (2–10%), entre o benchmark freemium de 2,1% e o hard paywall de 10,7% | ~5,0K   | US$21           | **~US$106K** (42K–212K) |
| SOM 2028 com Android                                    | + 10,4M Android × 0,1%                           | 0,1% de captura                                                                     | +10,4K  | US$6,5          | +US$68K, total ~US$174K |

Para comparação, a mesma conta sobre endereços (não recomendado) dá 34M × 6,5 ≈ US$221M e 47,3M × 6,5 ≈ US$307M, inflados por bots e por multicarteira.

## 5. Recálculo BOTTOM-UP

**TAM bottom-up, a partir de carteiras com ativos (ESTIMATIVA):**

- 8,38M carteiras com SOL e 13,07M com stablecoins (solana.com, set/2026). A sobreposição é desconhecida, então tomo **8,4M–13,1M carteiras**.
- ÷ 1,5 carteiras por pessoa (premissa de confiança baixa; a fonte só diz que "one person can control dozens of wallets") ≈ **5,6M–8,7M pessoas**.
- × US$6,5 ≈ **US$36M–57M/ano**.
- Subconjunto com saldo relevante: ~2,84M carteiras com 1–100 SOL (2,27M ociosas + 569K ativas; Forbes/Sandy Carter via Bitget, 23/03/2026; confiança **baixa/média**, análise on-chain não identificada).

**SOM bottom-up, pelo funil Seeker (ESTIMATIVA):**

- 100.908 Seekers ativados, dos quais 9.000+ são usuários ativos diários (Season 2, jun/2026).
- 20% dos ~9K engajados em 18 meses ≈ 1.800 cofres.
- 2% dos ~92K restantes ≈ 1.840 cofres.
- Total ≈ **3.600 cofres × US$21 ≈ US$77K/ano**.
- Valor protegido ≈ 3.600 × US$5.000 ≈ **US$18M**.
- Tração interna (10 alpha, 200+ SOL, 52 na waitlist) **não verificada**, conforme o pedido.

**Qual usar:** os dois métodos convergem. O TAM fica em ~US$36–100M/ano (o top-down usa a Phantom, que inclui outras chains; o bottom-up é mais conservador). O SOM fica em ~US$80–110K/ano em 18–24 meses. **No deck, usar o top-down como número principal e citar o bottom-up como checagem.**

---

## 6. O que colocar no slide (recomendação)

Trocar **US$16B / US$7,2B / US$72M** por:

- **TAM: 15M pessoas em autocustódia na Solana, guardando US$25B** (Phantom, jan/2025). Receita potencial ≈ **US$100M/ano** com ARPU misto de ~US$6,5.
- **SAM: ~10M no Android** (69% do mobile global, StatCounter set/2026), ≈ **US$67M/ano**.
- **SOM: ~100K Seekers ativados** (airdrop SKR, jan/2026). Meta de **5K cofres em 24 meses** ≈ **US$100K/ano e ~US$25M protegidos**.
- Rodapé: "Phantom (jan/2025) · Solana Mobile/airdrop SKR (jan/2026) · StatCounter (set/2026) · ARPU = mix de assinatura + taxa de 0,5%, premissas no apêndice".

Se o time preferir números mais "vendáveis", o defensável é mostrar o **valor protegido** (US$25B em autocustódia, só na Phantom), e não multiplicar pessoas por US$480. Um SOM de US$72M **não se sustenta** diante de um investidor que faça a conta 150K × US$480 = 100% de conversão.

---

## 7. Tabela de fontes

| #   | Título                                                                                      | URL                                                                                                                         | Data da fonte                      | Acesso                       | Confiança   |
| --- | ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- | ---------------------------- | ----------- |
| 1   | Solana Sees Record Holders but Bearish Signals Weigh on Price (Investing.com)               | https://www.investing.com/analysis/solana-sees-record-holders-but-bearish-signals-weigh-on-price-200678148                  | 2026-04-09                         | 2026-10-07                   | média       |
| 2   | Solana Token Holder Count Reaches Record 176.5 Million (Solana Compass)                     | https://solanacompass.com/news/solana-token-holder-count-reaches-record-1765-million-as-sol-trades-68-below-all-time-high   | 2026-08-23                         | 2026-10-07                   | média       |
| 3   | Token Terminal key metrics FAQ                                                              | https://tokenterminal.com/articles/token-terminal-key-metrics-faq                                                           | 2023-01-31                         | 2026-10-07                   | alta        |
| 4   | The Block Data, Solana on-chain metrics (active addresses monthly / daily 7DMA)             | https://www.theblock.co/data/on-chain-metrics/solana                                                                        | último ponto 2026-10-05            | 2026-10-07                   | média       |
| 5   | Solana active addresses fall to 12-month low (The Block)                                    | https://theblock.co/news/ecosystems/2025-11-12-solana-active-addresses-fall-to-12-month-low-as-memecoin-frenzy-fades-378234 | 2025-11-12                         | 2026-10-07                   | média       |
| 6   | Solana saw its highest monthly active addresses, over 123M in October (The Block)           | https://www.theblock.co/post/324273/solana-sees-record-high-monthly-active-addresses                                        | 2024-11-04                         | 2026-10-07                   | média       |
| 7   | Solana has 100M active wallets but most are empty (Cointelegraph)                           | https://cointelegraph.com/news/solana-has-100-m-active-wallets-but-most-are-empty                                           | 2024-10-09                         | 2026-10-07                   | média       |
| 8   | TechFlow newsletter (Artemis: Solana ~98M MAU)                                              | https://www.techflowpost.com/en-US/newsletter/108814                                                                        | 2025-12-17                         | 2026-10-07                   | baixa/média |
| 9   | Solana Ecosystem Roundup: September 2026 (solana.com)                                       | https://solana.com/news/solana-ecosystem-roundup-september-2026                                                             | 2026-09/10                         | 2026-10-07                   | alta        |
| 10  | Phantom Wallet raises $150 million at $3 billion valuation (The Block)                      | https://www.theblock.co/post/335305/phantom-wallet-raises-150-million-at-3-billion-valuation                                | 2025-01-16                         | 2026-10-07                   | média/alta  |
| 11  | Phantom raises $150 million at $3 billion valuation (Cointelegraph)                         | https://cointelegraph.com/news/phantom-raises-150-million-3-billion-valuation                                               | 2025-01-17                         | 2026-10-07                   | média       |
| 12  | Phantom, Fortune Crypto 100 (2026)                                                          | https://fortune.com/ranking/crypto/2026/phantom/                                                                            | 2026                               | 2026-10-07                   | média       |
| 13  | Phantom Wallet Statistics 2026 (CoinLaw)                                                    | https://coinlaw.io/phantom-wallet-statistics/                                                                               | atualizado 2026-09-29              | 2026-10-07                   | baixa       |
| 14  | Solana Saga successor 'Seeker' surpassing 140,000 presales (The Block)                      | https://www.theblock.co/post/317154/solana-seeker-saga-crypto-mobile-phone-successor-140000-presales                        | 2024-09-18                         | 2026-10-07                   | média       |
| 15  | The Protocol: Solana's Seeker Mobile Begins to Ship (CoinDesk)                              | https://www.coindesk.com/tech/2025/08/06/the-protocol-solana-s-seeker-mobile-begins-to-ship                                 | 2025-08-06                         | 2026-10-07                   | média       |
| 16  | Solana Mobile Ships Seeker with 150,000 Global Pre-orders (MobileIDWorld)                   | https://mobileidworld.com/solana-mobile-ships-seeker-web3-smartphone-with-150000-global-pre-orders/                         | 2025-08-05                         | 2026-10-07                   | média       |
| 17  | Solana Mobile says SKR token launch is coming in January (The Block)                        | https://www.theblock.co/post/381266/solana-mobile-skr-token-launch-in-january                                               | 2025-12-03                         | 2026-10-07                   | média       |
| 18  | Solana Mobile launches SKR token airdrop for Seeker users (The Block)                       | https://www.theblock.co/post/386449/solana-mobile-seeker-skr-token-airdrop                                                  | 2026-01-20                         | 2026-10-07                   | média       |
| 19  | Solana Mobile Airdropping 1.8B SKR Tokens to Users (CoinMarketCap Academy)                  | https://coinmarketcap.com/academy/article/solana-mobile-airdropping-18b-skr-tokens-to-users                                 | jan/2026                           | 2026-10-07                   | média/alta  |
| 20  | Solana Mobile, exhibitor MWC Barcelona 2027                                                 | https://www.mwcbarcelona.com/exhibitors/34827-solana-mobile                                                                 | sem data (evento mar/2027)         | 2026-10-07                   | baixa/média |
| 21  | Post @solanamobile no X ("200,000+ devices shipped")                                        | https://x.com/solanamobile/status/2023770158645342255                                                                       | fev/2026 (snippet de busca)        | 2026-10-07 (402, não aberto) | baixa       |
| 22  | Solana Mobile June Recap (SolanaFloor)                                                      | https://solanafloor.com/news/solana-mobile-june-recap-1-000-apps-publishing-portal-update-and-de-fi-portfolio-tracking      | jun/2026                           | 2026-10-07                   | média       |
| 23  | Seeker Genesis Token (docs Solana Mobile)                                                   | https://docs.solanamobile.com/solana-mobile-stack/seeker-genesis-token.md                                                   | atual                              | 2026-10-07                   | alta        |
| 24  | Solana docs, Fees                                                                           | https://solana.com/docs/core/fees                                                                                           | atual                              | 2026-10-07                   | alta        |
| 25  | Mobile OS Market Share Worldwide (StatCounter)                                              | https://gs.statcounter.com/os-market-share/mobile/worldwide                                                                 | set/2026                           | 2026-10-07                   | alta        |
| 26  | State of Subscription Apps 2026 in 10 minutes (RevenueCat)                                  | https://www.revenuecat.com/blog/growth/subscription-app-trends-benchmarks-2026                                              | 2026-03-19 (atualizado 2026-04-22) | 2026-10-07                   | alta        |
| 27  | Cipherwill pricing                                                                          | https://www.cipherwill.com/pricing                                                                                          | atual                              | 2026-10-07                   | alta        |
| 28  | Casa pricing                                                                                | https://casa.io/pricing                                                                                                     | atual                              | 2026-10-07                   | alta        |
| 29  | Analysis: Over 2.27 million wallets holding 1–100 SOL are inactive (Bitget, citando Forbes) | https://www.bitget.com/news/detail/12560605293890                                                                           | 2026-03-23                         | 2026-10-07                   | baixa/média |

Não encontrado / não verificado:

- painel do Token Terminal (JS, sem dados na página);
- post oficial da Phantom sobre a Série C (404);
- contagem on-chain de Seeker Genesis Tokens (Helius 401);
- artigo da Forbes (403);
- DefiLlama, receita da Phantom (403).
