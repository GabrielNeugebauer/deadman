# Deadman: pesquisa de mercado

Relatório do editor-chefe. Data de corte: **2026-10-07**. Todas as fontes foram acessadas nessa data; a lista completa, com URL, data da fonte e onde cada uma é usada, está em [`fontes.md`](fontes.md). As notas brutas de cada frente estão em [`_notas/`](_notas/) e servem de anexo.

Documentos irmãos:

- [`correcoes-deck.md`](correcoes-deck.md): uma linha por dado do deck, com status, valor correto e texto sugerido.
- [`precificacao.md`](precificacao.md): benchmarks, simulação de 3 anos e recomendação de preço.
- [`fontes.md`](fontes.md): todas as fontes.

Convenções usadas em todo o relatório:

- **[FATO]**: número lido na fonte citada. **[ESTIMATIVA]**: conta, premissa ou inferência nossa. **[INTERNO]**: vem do repositório ou do time e não foi verificado fora dele.
- Confiança: **alta** (fonte primária lida), **média** (secundária confiável que cita a primária, ou primária lida só em parte), **baixa** (agregador, snippet de busca, número sem metodologia).
- "Não encontrado" significa que procuramos e não achamos. Nenhum número foi preenchido por suposição.

---

## Sumário executivo

**O problema existe, é medido e está crescendo. O deck acerta a tese, mas erra a conta de mercado e tem três exemplos frágeis que um jurado atento derruba.**

**O que está sólido** (fonte primária lida pelo editor em 2026-10-07):

1. **Coação física cresce:** 72 wrench attacks verificados em 2025, +75% sobre 2024, US$40,9M em perdas confirmadas, Europa com mais de 40% dos casos (CertiK, 02/02/2026; alta). A lista aberta de Jameson Lopp tem ~86 casos em 2025 contra ~41 em 2024, 12 deles no Brasil (média).
2. **Quase ninguém tem plano:** entre 2.000 britânicos com US$10 mil+ em autocustódia, 52% não têm a cripto clara no plano sucessório, só 55% têm arranjo formal de acesso e, em média, estimam que 38% da cripto ficaria inacessível se morressem (CoinCover/Censuswide, PDF de 02/07/2026; média-alta).
3. **O que trava não é preço, é inércia e confiança:** "não priorizei" 30%, "complexo" 24%, "segurança" 23%; custo só 17% e "não confio em nenhum provedor" 16% (mesma fonte).
4. **Perda de acesso é comum:** 35% dos detentores dos EUA já perderam acesso a uma carteira ou conta; 31% deles nunca recuperaram (Oobit, n=1.000, abr/2026; média).
5. **A base Solana é grande e alvo:** Phantom declarou 15M de usuários ativos mensais e US$25B em autocustódia (jan/2025; média-alta). Solana teve o maior número de vítimas de comprometimento de carteira pessoal em 2025, ~26.500 (Chainalysis, 18/12/2025; alta).
6. **Brasil é mercado crível:** 29M de brasileiros já investiram em cripto; ~6,75M (4% da população) guardam as próprias chaves (Paradigma/Datafolha, ago/2026; média). Brasil é 5º no índice de adoção da Chainalysis 2025 (alta).

**O que precisa mudar no deck** (detalhe em `correcoes-deck.md`):

1. **TAM/SAM/SOM (US$16B / US$7,2B / US$72M) não se sustentam.** As três camadas multiplicam por US$480/ano, ou seja, supõem que 100% pagam o plano mais caro. O TAM usa endereços (não pessoas; em out/2024, 86% dos ~100M endereços ativos tinham 0 SOL). O SOM usa 150 mil **pré-vendas** do Seeker como se fossem donos. Recontado: TAM ~15M pessoas e US$25B em autocustódia (≈ US$60–100M/ano de receita potencial), SAM ~10M no Android, SOM ~100 mil Seekers ativados, com meta de ~5 mil cofres em 24 meses.
2. **QuadrigaCX é um contraexemplo.** O regulador de Ontário concluiu que as perdas (pelo menos C$169M) vieram de fraude do CEO, "an effective Ponzi scheme", não da senha que morreu com ele. Os US$190M da manchete eram o total devido, fiat incluído.
3. **"Noiva esvaziou a carteira" não tem fonte localizável.** Retirar até ter veículo e link.
4. **"~60% preferem autocustódia" (CoinLaw)** vem de agregador sem fonte primária. Trocar por Tangem/Protocol Theory 2026 (66% consideram a autocustódia importante, 88% ainda deixam ativos em corretora; n=3.172, EUA).
5. **Modelo de negócio contraditório:** a "taxa no cancelamento" não existe no programa on-chain; o README diz 2%/3% de taxa e "devnet / unaudited", enquanto o deck diz 0,5% e "mainnet live"; o deck promete "fake wallet" e o README diz "time-lock, not a decoy".

**As três mudanças recomendadas:**

1. **Refazer o slide de mercado** sobre pessoas e valor protegido (Phantom 15M / US$25B; ~100 mil Seekers ativados), com ARPU realista.
2. **Reprecificar:** grátis com 0,5% só na liberação e nenhuma taxa de saída; plano Plus a ~US$79/ano (testar US$59/79/99), pago em SKR com desconto moderado e burn de 0 a 10%. Hoje o plano de US$40/mês só compensa para quem move mais de US$96 mil por ano e custa 12× o Cipherwill e ~5× o Kresus (US$99,99/ano, Solana, mobile).
3. **Alinhar a narrativa à verdade do produto antes de 08/out:** um status só (mainnet alpha, sem auditoria), uma taxa só, e "PIN de coação: o app parece normal e o cofre trava" no lugar de "fake wallet". O diferencial anticoerção é real entre apps de herança, mas não no mercado inteiro (Coldcard e Ledger têm carteiras-isca).

**Limitações:** as cotas de busca das sessões de pesquisa acabaram antes do fim; ficaram sem fonte a matéria da Exame, a da "noiva", o catálogo do dApp Store, a busca do Colosseum Arena e a contagem on-chain de Seekers (a chave da Helius retornou 401). Não existe pesquisa publicada de disposição a pagar por herança cripto; o preço recomendado é estimativa e precisa de teste com a waitlist.

---

## Verificação do editor (amostragem de links)

Antes de escrever, o editor reabriu 26 dos links que sustentam correções do deck e a precificação. Resultado:

| #   | Fonte reaberta                                   | O que as notas diziam                                                     | Resultado em 2026-10-07                                                                                                                                                                                                                                        |
| --- | ------------------------------------------------ | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | CertiK, Skynet Wrench Attacks Report             | 72 casos, +75%, US$40,9M, Europa >40%; "a CertiK recomenda panic wallets" | **Números confirmados.** **A recomendação de "panic wallet" NÃO está na página da CertiK** nem é atribuída a ela pela Cointelegraph. Afirmação rebaixada e removida do relatório                                                                               |
| 2   | Cointelegraph sobre o relatório CertiK           | ~41 em 2024; França 19                                                    | Confirmado: França 19. O número de 2024 não é dado explicitamente; ~41 é derivado de 72/1,75                                                                                                                                                                   |
| 3   | OSC, relatório QuadrigaCX                        | lido na fonte                                                             | **403 no acesso do editor.** Conteúdo confirmado via The Block (11/06/2020): perdas ≥ C$169M, "effective Ponzi scheme", contas falsas de Cotten. Confiança mantida em alta para a conclusão, média para os 76 mil clientes                                     |
| 4   | Oobit, lost-or-locked-out                        | 35%, 31%, n=1.000 EUA                                                     | Confirmado. Página sem data explícita. Dado extra: entre os que perderam acesso, 49% em autocustódia, 36% em conta de corretora                                                                                                                                |
| 5   | Livecoins, celular roubado em SP                 | R$920 mil, Binance + Trezor                                               | Confirmado (16/02/2024; R$920 mil no corpo; 2,93 BTC ≈ R$626 mil rastreados)                                                                                                                                                                                   |
| 6   | Solana docs, Fees                                | 5.000 lamports por assinatura                                             | Confirmado: "per-signature, split 50% burned / 50% to the validator"                                                                                                                                                                                           |
| 7   | The Block, Phantom Série C                       | 15M MAU, US$25B                                                           | Confirmado (16/01/2025)                                                                                                                                                                                                                                        |
| 8   | CoinMarketCap Academy, airdrop SKR               | 100.908 usuários                                                          | Confirmado: "1,819,755,000 SKR to 100,908 users". A página traz "January 21, 2025", erro evidente de ano (o airdrop foi em jan/2026, The Block 20/01/2026)                                                                                                     |
| 9   | Solana Mobile, "Your SKR guide"                  | ~72 mil carteiras                                                         | Confirmado: "distributed to almost 72,000 wallets"; 40%+ em stake; 50% off no Seeker pago em SKR até 21/02/2026. **Nenhuma menção a burn**                                                                                                                     |
| 10  | Blockonomi, Solana Mobile no MWC 2026            | 200 mil+ aparelhos, 85 mil+ carteiras semanais                            | Confirmado (02/03/2026): 200 mil+ aparelhos **Saga + Seeker somados**, 85 mil+ carteiras ativas semanais, 75 mil+ resgataram SKR, 46% em stake                                                                                                                 |
| 11  | Investing.com, Token Terminal                    | ~34M endereços ativos mensais                                             | Confirmado (09/04/2026): "around 34 million monthly active addresses", 40M em março                                                                                                                                                                            |
| 12  | Solana Ecosystem Roundup set/2026                | 8,38M com SOL; 13,07M com stablecoin                                      | Confirmado                                                                                                                                                                                                                                                     |
| 13  | StatCounter, SO mobile                           | Android 69,17%                                                            | Confirmado (set/2026; iOS 30,81%)                                                                                                                                                                                                                              |
| 14  | Chainalysis, blog de 19/11/2020                  | 3,7M BTC                                                                  | **Parcial.** A página diz que "lost" = sem movimento há 5+ anos e que 14,8M BTC **não** são perdidos; não escreve "3,7M". O 3,7M é derivado (≈18,5M minerados − 14,8M)                                                                                         |
| 15  | The Block sobre Chainalysis, 18/06/2020          | ~20% perdidos                                                             | Confirmado: "Another 20% of the current Bitcoin supply hasn't been moved in five years or longer, what Chainalysis calls 'lost Bitcoin'"                                                                                                                       |
| 16  | Sentença Howells [2025] EWHC 22 (Ch)             | 8.000 BTC, ação extinta                                                   | Confirmado (09/01/2025; HD no aterro em 05/08/2013; "in excess of £600 million")                                                                                                                                                                               |
| 17  | Tangem / Protocol Theory (Global Fintech Series) | 66% importante; 88% em corretora                                          | Confirmado (24/04/2026; n=3.172 EUA). **Cold wallet: 33%** no release; o "15%" que aparece nas notas B vem de outro veículo e conflita. Usar 33%                                                                                                               |
| 18  | CoinCover, PDF "Crypto Inheritance Black Hole"   | 52%, 55%, 38%, 72%, 78%, barreiras                                        | Confirmado (texto extraído do PDF; metadado 02/07/2026). **Correção:** 49% acham que os herdeiros acessariam **toda** a cripto (as notas B diziam o contrário). 51% acham que os herdeiros achariam a informação sem ajuda; 41% acham que precisariam de apoio |
| 19  | Cipherwill, pricing                              | US$40/ano                                                                 | Confirmado: Premium US$40/ano (de US$60), cobrado anualmente; vault de chaves/seed só no Premium; plano grátis vitalício                                                                                                                                       |
| 20  | Heres Protocol, pricing                          | US$2 + US$2/mês                                                           | Confirmado: "$2 one-time creation fee", "$2/month while your capsule is active"; só devnet mencionada                                                                                                                                                          |
| 21  | Kresus, press release (Chainwire, 09/07/2026)    | US$99,99/ano                                                              | Confirmado: US$99,99/ano, não custodial, liberação após período de inatividade. **Redes suportadas não constam no release** (Solana vem da HackerNoon, média)                                                                                                  |
| 22  | Nunchuk, pricing                                 | Honey Badger US$480/ano                                                   | Confirmado (Iron Hand US$120 sem herança; Honey Badger US$480 com herança; Premier US$2.100)                                                                                                                                                                   |
| 23  | Casa, pricing                                    | US$250 / 2.100 / 7.500                                                    | Confirmado; herança incluída em todos; BTC, ETH e stablecoin; Solana não aparece                                                                                                                                                                               |
| 24  | RevenueCat, SOSA 2026                            | 2,1% freemium; 10,7% hard paywall                                         | Confirmado (D35). Retenção anual após 1 ano: 27–28%                                                                                                                                                                                                            |
| 25  | Chainalysis, roubos 2025                         | 158 mil, US$713M, Solana ~26.500                                          | Confirmado (18/12/2025)                                                                                                                                                                                                                                        |
| 26  | GitHub jlopp/physical-bitcoin-attacks            | 86 em 2025, 42 em 2024                                                    | Recontado pelo editor (regex sobre as datas do README): 2024 = 41, 2025 = 86, 2026 até agora = 62. Contagem aproximada; lista não exaustiva                                                                                                                    |

Também conferido no repositório, sem editar `[INTERNO]`: o README diz "2% on the Solana rail, 3% on private rails", "Status: unaudited hackathon build. The program runs on devnet" e "Duress is a time-lock, not a decoy". `split_fee` só é chamado em `execute_*_rule` e `release_vested_*`; `withdraw_*`, `close_vault` e `revoke_vesting` não cobram taxa. O plano mensal no README é de 10 USDC por 30 dias em devnet, com **mínimo de 12 meses** para começar.

---

## A. Os números do deck

Resumo; o texto sugerido para cada slide está em `correcoes-deck.md`.

### A.1 Fatos do slide 01 (itens 1 a 5)

| #   | Deck                                           | Status                         | O que é verdade                                                                                                                                                                                                                                                                                            | Data       | Conf.      | Tipo   |
| --- | ---------------------------------------------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ---------- | ------ |
| 1   | ~60% preferem autocustódia (CoinLaw)           | Fonte fraca                    | A CoinLaw diz 59% sem citar origem. Origem provável: N1, 2025 Crypto End-User Report (~250 respostas). Melhor dado: 66% consideram a autocustódia importante, 88% ainda guardam em corretora, 33% usam cold wallet (Tangem/Protocol Theory, n=3.172, EUA; pesquisa encomendada por fabricante de carteira) | abr/2026   | média      | [FATO] |
| 2   | 3,7M BTC parados há 5+ anos (Chainalysis 2020) | Confirmado com ressalvas       | Chainalysis: ~20% da oferta sem movimento há 5+ anos, que ela chama de "lost" (jun/2020). ≈3,7M é derivado e inclui ~1M atribuído a Satoshi. Faixa de outras estimativas: 1,46M (Glassnode, piso) a 3,8M (Chainalysis 2017, teto)                                                                          | jun/2020   | média-alta | [FATO] |
| 3   | 72 wrench attacks em 2025, +75% (CertiK)       | Confirmado                     | 72 incidentes verificados, +75%; US$40,9M em perdas (+44%); Europa >40%; França 19                                                                                                                                                                                                                         | 02/02/2026 | alta       | [FATO] |
| 4   | 8.000 BTC num HD no lixo (Howells)             | Confirmado como alegação       | Sentença registra a alegação de 8.000 BTC; ação extinta em 09/01/2025; permissão para recorrer negada em 13/03/2025 (Decrypt). Reportagens até 2021 falavam em 7.500                                                                                                                                       | 09/01/2025 | alta       | [FATO] |
| 5a  | "1 em cada 3 perdeu acesso" (Exame/Oobit)      | Dado certo, veículo não achado | 35% de 1.000 detentores **dos EUA** perderam acesso a carteira **ou conta**; 31% deles nunca recuperaram, por qualquer causa. A matéria da Exame não foi localizada                                                                                                                                        | abr/2026   | média      | [FATO] |
| 5b  | R$1 milhão, celular roubado em SP              | Confirmado com ressalva        | Livecoins: R$920 mil no corpo; fundos na Binance (custodial) e numa Trezor; ~R$626 mil rastreados                                                                                                                                                                                                          | 16/02/2024 | alta       | [FATO] |
| 5c  | Noiva esvaziou a carteira com a seed           | Sem fonte                      | Não encontrado. Alternativa documentada: Yuen vs. Li (Reino Unido, seed capturada por câmeras escondidas, 2.323 BTC)                                                                                                                                                                                       | —          | —          | —      |
| 5d  | US$190M congelados após a morte (QuadrigaCX)   | Enganoso                       | US$190M ≈ C$250M devidos no total, fiat incluído. A OSC concluiu fraude: perdas ≥ C$169M, ~C$115M do trading fraudulento de Cotten, "effective Ponzi scheme"                                                                                                                                               | 11/06/2020 | alta       | [FATO] |

### A.2 Mercado e rede (itens 6 a 9)

| #   | Deck                                              | Status                      | O que é verdade                                                                                                                                                                                     | Data         | Conf.      |
| --- | ------------------------------------------------- | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | ---------- |
| 6   | TAM: 33,9M MAU × US$480 = US$16B (Token Terminal) | Número existe; uso errado   | ~34M **endereços** ativos mensais (Token Terminal via Investing.com). Outras medições: 47,3M (The Block, último ponto 05/10/2026), ~98M (Artemis, dez/2025), 123M (out/2024). Endereço não é pessoa | abr/2026     | média      |
| 7   | SAM: 15M Phantom × US$480 = US$7,2B               | Número certo; camada errada | 15M MAU e US$25B em autocustódia, declarados pela empresa. Phantom é multichain e inclui iOS e desktop; serve como proxy de TAM em pessoas                                                          | 16/01/2025   | média-alta |
| 8   | SOM: 150K donos de Seeker × US$480 = US$72M       | Rótulo errado               | 150K são **pré-vendas** (ago/2025). Aparelhos ativados: 100.908 contemplados no airdrop SKR (jan/2026); ~72–75 mil resgataram. 200K+ aparelhos enviados somam Saga e Seeker                         | jan–mar/2026 | média-alta |
| 9   | Taxa base ~0,000005 SOL por transação             | Impreciso                   | 5.000 lamports **por assinatura**, 50% queimados. Check-in patrocinado pela Kora (2 assinaturas) = 10.000 lamports ≈ US$0,0012 [ESTIMATIVA, SOL a US$115,65]                                        | atual        | alta       |

### A.3 Recálculo de TAM/SAM/SOM [ESTIMATIVA sobre FATOS]

Erros de método do slide atual: (1) endereço tratado como pessoa; (2) ×US$480 supõe 100% pagando o plano mais caro, quando a mediana de conversão de apps freemium é 2,1% (RevenueCat 2026); (3) SAM inclui iOS, desktop e outras chains, que o produto não alcança antes de meados de 2027; (4) SOM igual a 100% da base, quando SOM é a fatia capturável em 2–3 anos; (5) rótulos sem mês ("Phantom 2025" é jan/2025).

**ARPU realista.** Duas leituras, porque o modelo de preço vai mudar:

| Modelo                                                         | Conservador | Base       | Otimista   | Seeker (cripto-nativo) | Premissas                                                                                                                                                                                           |
| -------------------------------------------------------------- | ----------- | ---------- | ---------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Atual do deck (0,5% na execução e no cancelamento + US$40/mês) | US$2,8/ano  | US$6,5/ano | US$17/ano  | US$21/ano              | Notas A2: 0,25–2% assinam (só baleias, break-even de US$96 mil/ano), saldo de US$1.000–5.000 passando por uma taxa a cada 2–3 anos. **Depende da taxa de cancelamento, que não existe no programa** |
| Recomendado (0,5% só na liberação + Plus US$79/ano)            | US$1,6/ano  | US$4,1/ano | US$7,1/ano | ~US$7/ano              | Conversão de 2% / 5% / 8% (8% no Seeker) × ~US$75 (mix USD/SKR) + 0,5% sobre 3–8% do saldo liberado por ano. Cálculo do editor                                                                      |

**Camadas:**

| Camada                   | Base [FATO]                                                  | Filtro [ESTIMATIVA]                                     | Pessoas    | Receita/ano (modelo recomendado – atual) | Valor em jogo                      |
| ------------------------ | ------------------------------------------------------------ | ------------------------------------------------------- | ---------- | ---------------------------------------- | ---------------------------------- |
| **TAM**                  | 15M MAU Phantom (jan/2025), proxy de pessoas em autocustódia | 100% (definição)                                        | 15M        | **~US$60M – US$100M**                    | US$25B em autocustódia na Phantom  |
| TAM (checagem bottom-up) | 8,38M carteiras com SOL e 13,07M com stablecoin (set/2026)   | ÷ 1,5 carteira por pessoa (premissa de confiança baixa) | 5,6–8,7M   | US$23M – US$57M                          | —                                  |
| **SAM**                  | 15M                                                          | × 69,17% Android (StatCounter, set/2026)                | ~10,4M     | **~US$43M – US$67M**                     | —                                  |
| SAM até meados de 2027   | 100.908 Seekers contemplados no airdrop (jan/2026)           | 100%                                                    | ~101K      | ~US$0,7M – US$2,1M                       | —                                  |
| **SOM (24 meses)**       | ~101K Seekers                                                | 5% de captura (faixa 2–10%)                             | ~5K cofres | **~US$35K – US$106K**                    | ~US$25M protegidos (5K × US$5.000) |

Os dois métodos (top-down e bottom-up) convergem na ordem de grandeza: dezenas de milhões por ano no TAM, não bilhões, e receita de seis dígitos no SOM. **Para o slide, o número mais forte e defensável é o valor protegido** (US$25B em autocustódia só na Phantom) e a meta de cofres, não pessoas × US$480.

---

## B. Tamanho e urgência do problema

### B.1 Estoque perdido

| Dado                                                                            | Fonte                     | Data       | Conf.      | Tipo     |
| ------------------------------------------------------------------------------- | ------------------------- | ---------- | ---------- | -------- |
| 1,4556M BTC "probably lost" (parados desde jul/2010): piso conservador          | Glassnode Studio          | 2026-10-07 | alta       | [FATO]   |
| 2,78M a 3,79M BTC perdidos (supõe perdidos os ~1M de Satoshi)                   | Chainalysis via Fortune   | 25/11/2017 | média      | [FATO]   |
| ~20% da oferta (≈3,7M BTC) sem movimento há 5+ anos, chamado de "lost"          | Chainalysis via The Block | 18/06/2020 | média-alta | [FATO]   |
| 17% da oferta é "ancient supply" (10+ anos); "uma parte desconhecida" é perdida | Fidelity Digital Assets   | 18/06/2025 | alta       | [FATO]   |
| 6–7M BTC "irrecuperáveis" (Cane Island)                                         | Bitcoin.com News          | 27/03/2023 | baixa      | não usar |

**Qual usar:** faixa **1,5M a 3,8M BTC** [ESTIMATIVA: ~7% a ~19% de ~19,9M minerados; o total minerado não foi reverificado]. Se o deck mantiver um número só, "~20% da oferta (≈3,7M BTC) não se move há 5+ anos (Chainalysis, 2020)".

Casos: Howells (8.000 BTC, alta), Matthew Mellon (US$193M em XRP recuperados com ajuda da Ripple, 2018, média), Mircea Popescu (saldo nunca comprovado, baixa). QuadrigaCX **não** é caso de chave perdida (ver A.1).

### B.2 Perda de acesso no varejo

- [FATO] 35% dos detentores dos EUA perderam acesso a carteira ou conta; 31% deles nunca recuperaram; 47% recuperaram. Causas: senha esquecida 33%, seed perdida 21%, 2FA 20%. Entre os que perderam acesso, 49% foi em autocustódia e 36% em conta de corretora. Só 15% já testaram o processo de recuperação (Oobit, n=1.000, abr/2026; média; empresa do setor).
- [FATO] 72% dos britânicos com US$10 mil+ em autocustódia já viveram ou presenciaram um "quase perdi o acesso" (CoinCover, 2026; média-alta).

### B.3 Coação física

| Dado                                                                                                 | Fonte                             | Data       | Conf. |
| ---------------------------------------------------------------------------------------------------- | --------------------------------- | ---------- | ----- |
| [FATO] 72 ataques em 2025 (+75%), US$40,9M (+44%), Europa >40%, França 19                            | CertiK                            | 02/02/2026 | alta  |
| [FATO] Ataques físicos correlacionados ao preço do BTC; 2025 no ritmo do dobro do pior ano anterior  | Chainalysis, Mid-Year Update      | 17/07/2025 | alta  |
| [FATO] Lista aberta: ~41 casos em 2024, ~86 em 2025, ~62 em 2026 até 07/10; 12 no Brasil             | Lopp, GitHub (contagem do editor) | 2026-10-07 | média |
| [FATO] Operação Criptonita (SP): 4 presos; sequestro de corretor de cripto no Shopping Cidade Jardim | Jornal de Brasília                | 07/04/2026 | média |

**Conflito:** CertiK (72) e Lopp (~86) usam metodologias diferentes; a lista do Lopp inclui roubos de caixas eletrônicos de BTC e extorsões. **Usar a CertiK no deck**, citar o Lopp como base aberta.

### B.4 Celular e carteira como alvo

- [FATO] 158 mil comprometimentos de carteiras pessoais em 2025, ≥80 mil vítimas, US$713M roubados; Solana teve o maior número de vítimas (~26.500) (Chainalysis, 18/12/2025; alta).
- [FATO] Brasil: 792.284 roubos e furtos de celular registrados em 2025 (Anuário FBSP via CNN Brasil; média). A mesma matéria cita 830.890 no título; 792.284 bate com a soma de roubos (308.723) e furtos (483.581). Usar 792.284 e conferir no PDF do FBSP.

### B.5 Planejamento sucessório

| Dado                                                                                                                                     | Fonte                                                                            | Data           | Conf.          | Tipo     |
| ---------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | -------------- | -------------- | -------- |
| 52% sem cripto clara no plano sucessório (32% com testamento que não cobre cripto, 12% não sabem, 8% sem testamento)                     | CoinCover/Censuswide, n=2.000 Reino Unido, 35–50 anos, US$10 mil+ e autocustódia | PDF 02/07/2026 | média-alta     | [FATO]   |
| Só 55% têm arranjo formal de acesso; 35% dependem de arranjo informal                                                                    | idem                                                                             | idem           | média-alta     | [FATO]   |
| 49% acham que os herdeiros acessariam **toda** a cripto; 33% "a maior parte"; 51% acham que os herdeiros achariam a informação sem ajuda | idem                                                                             | idem           | média-alta     | [FATO]   |
| Em média, 38% da cripto ficaria inacessível; 32% acham que ao menos metade ficaria                                                       | idem                                                                             | idem           | média-alta     | [FATO]   |
| 78% querem uma solução de herança cripto                                                                                                 | idem                                                                             | idem           | média-alta     | [FATO]   |
| Só 23% têm plano documentado; 89% se preocupam                                                                                           | Cremation Institute via Cointelegraph, n=1.150                                   | 08/07/2020     | média          | [FATO]   |
| "23% Fidelity 2025"                                                                                                                      | só em blogs                                                                      | —              | não encontrado | não usar |
| 24% dos adultos dos EUA têm testamento (33% em 2022)                                                                                     | Caring.com/YouGov                                                                | 2025           | média-alta     | [FATO]   |

A CoinCover vende a solução e a amostra é só do Reino Unido: citar com essas ressalvas. Os dois números (52% em 2026, 23% em 2020) não se contradizem; medem populações diferentes.

### B.6 Autocustódia e mobile

- [FATO] ~716M donos de cripto no mundo; usuários de carteira mobile em recorde, +20% a/a (a16z State of Crypto, 22/10/2025; alta).
- [FATO] Phantom: 15M MAU, US$25B (16/01/2025; média-alta). Os números de 2026 que circulam (9,8M, 17M, 22M) se contradizem e vêm de agregadores: não usar.
- [FATO] Seeker: 150 mil pré-vendas (ago/2025); 100.908 contemplados no airdrop (jan/2026); ~72 mil carteiras receberam o SKR distribuído (guia oficial) e 75 mil+ resgataram (MWC); 85 mil+ carteiras ativas semanais e 200 mil+ aparelhos Saga + Seeker (02/03/2026). Média-alta.
- [FATO] Reino Unido: compra via exchange centralizada subiu para 73% (FCA/YouGov, 16/12/2025; alta). Mostra que "preferir autocustódia" e "usar autocustódia" são coisas diferentes.

### B.7 Brasil

| Dado                                                                                                 | Fonte                                      | Data          | Conf.      | Tipo                               |
| ---------------------------------------------------------------------------------------------------- | ------------------------------------------ | ------------- | ---------- | ---------------------------------- |
| 29M de brasileiros (17,2% da população 16+) já investiram em cripto                                  | Paradigma/Datafolha, n=2.004               | 18–19/08/2026 | média-alta | [FATO]                             |
| Autocustódia subiu de 2,2% para 4% da população (~6,75M); 26% dos investidores usam carteira própria | idem, via Let's Money                      | 19/08/2026    | média      | [FATO]                             |
| 4.667.864 CPFs com operações declaradas em jun/2026 (mede quem operou, não quem detém)               | Receita Federal, dados abertos             | 26/08/2026    | alta       | [FATO]                             |
| 5º no índice global de adoção                                                                        | Chainalysis                                | 02/09/2025    | alta       | [FATO]                             |
| 38.740 testamentos lavrados em 2025, recorde                                                         | CNB, Cartório em Números, via O Imparcial  | fev/2026      | média      | [FATO]                             |
| STJ, REsp 2.124.424/SP: "inventariante digital" (o caso era um iPad, não cripto)                     | Migalhas, InfoMoney/CNB-SP                 | set/2025      | média      | [FATO]                             |
| ~47 mil brasileiros em autocustódia morrem por ano                                                   | 6,75M × ~0,7% (mortalidade não verificada) | —             | baixa      | [ESTIMATIVA], só ordem de grandeza |

---

## C. Concorrência

### C.1 Item (10) do deck

| Afirmação                               | Status                  | Evidência                                                                                                                      | Conf. |
| --------------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ----- |
| "15+ projetos de herança cripto"        | Confirmado, conservador | 20+ produtos com site (tabela C.2) e 34 repositórios Solana de herança/DMS no GitHub (API de busca, 07/10), 25 criados em 2026 | alta  |
| Cipherwill US$40/ano                    | Confirmado              | Premium US$40/ano (de US$60); grátis vitalício sem vault de chaves                                                             | alta  |
| Cipherwill é web app                    | Confirmado              | PWA, sem app nas lojas                                                                                                         | alta  |
| Libera chaves privadas após inatividade | Confirmado              | Check-in padrão a cada 3 meses; no dia 100 de silêncio, chaves de decriptação vão aos beneficiários. Não move ativos on-chain  | alta  |
| Sem proteção contra coação              | Confirmado por ausência | Nenhuma menção no site                                                                                                         | média |

**Atenção no slide:** pôr "Cipherwill US$40" ao lado de "Deadman US$40" confunde, porque um é por ano e o outro por mês (o Deadman custa 12× mais).

### C.2 Mapa de concorrentes [FATO salvo indicação]

| Projeto                    | Preço                                                                                      | Plataforma        | Solana                  | Coação                                        | Status / tração                                                                                      | Conf.                        |
| -------------------------- | ------------------------------------------------------------------------------------------ | ----------------- | ----------------------- | --------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------- |
| **Heres Protocol**         | US$2 de criação + US$2/mês por cápsula (a doc técnica diz 0,05 SOL e sem taxa de execução) | web               | nativo, **só devnet**   | não                                           | 170 cápsulas, 53,9 SOL (devnet). Sem check-in: atividade da carteira = sinal de vida. TEE MagicBlock | alta                         |
| **Kresus Inheritance**     | US$99,99/ano                                                                               | carteira (mobile) | segundo a HackerNoon    | não informado                                 | lançado em 09/07/2026; não custodial; gatilho por inatividade                                        | alta (preço) / média (redes) |
| **Cipherwill**             | grátis / US$40/ano                                                                         | PWA               | indireto (guarda seeds) | não                                           | "4.6/5", sem número de usuários                                                                      | alta                         |
| **Dead Man's Vault (DMV)** | 0,01 SOL                                                                                   | Android/Seeker    | nativo, devnet          | não                                           | hackathon MONOLITH, sem prêmio                                                                       | alta                         |
| **BSafe**                  | grátis (1% no claim); Premium 1 SOL; 50 SOL/ano                                            | web               | nativo, devnet          | não                                           | Colosseum Crypto World's Fair                                                                        | alta                         |
| **Casa**                   | US$250 / 2.100 / 7.500 por ano, herança incluída                                           | iOS, Android, web | não (BTC, ETH, stable)  | emergency lockdown (72h / vídeo)              | não divulgada                                                                                        | alta                         |
| **Nunchuk**                | Honey Badger US$480/ano (herança); Iron Hand US$120 (sem)                                  | mobile, desktop   | não (só BTC)            | emergency lockdown                            | não divulgada                                                                                        | alta                         |
| **Vault12 Guard**          | Inheritance US$29,99/mês; 50% off em VGT                                                   | iOS, Android      | indireto (seeds)        | não                                           | 4,6★, 47 avaliações (App Store EUA)                                                                  | alta                         |
| **Unchained**              | Vault US$250/ano; Signature US$6.000 no 1º ano                                             | web + hardware    | não (só BTC)            | não encontrada                                | —                                                                                                    | alta                         |
| **Bitkey**                 | hardware US$250, herança incluída (espera de 6 meses)                                      | app + hardware    | não (só BTC)            | não                                           | —                                                                                                    | alta                         |
| **Ledger Recover**         | ~US$9,99/mês (imprensa, 2023)                                                              | Ledger            | indireto                | no hardware: passphrase + PIN com contas-isca | —                                                                                                    | média                        |
| **Inheriti**               | €39,99 único; exige token SHA                                                              | web               | não                     | não                                           | —                                                                                                    | alta                         |
| **Sarcophagus**            | gas + SARCO                                                                                | web dApp          | não (BASE)              | não                                           | captou US$5,47M em 2022                                                                              | média                        |
| **Deadhand**               | open source                                                                                | —                 | —                       | "Duress Mode" (apaga dados)                   | site 404; 0 downloads/semana                                                                         | média                        |

### C.3 Leitura competitiva [ESTIMATIVA]

1. **Nenhum concorrente de herança em Solana declara mainnet ou PIN de coação** (READMEs dos 34 repositórios e sites de Heres e DMV; alta para os encontrados).
2. **Anticoerção existe fora da categoria:** Coldcard (Trick PINs com "duress wallet"), Ledger (contas-isca), Casa e Nunchuk (lockdown), Deadhand (apaga dados). "O único com proteção contra coação" só se sustenta como "o único app de herança que encontramos".
3. **Concorrência no mesmo hackathon:** AfterKey, legacy-ledger, bsafe e deathclock se declaram submissões do Colosseum Crypto World's Fair. 6 repositórios de herança em Solana foram criados entre 22/09 e 07/10/2026.
4. **Ameaça real de médio prazo:** carteiras embutirem herança como recurso (Casa já inclui; Kresus lançou em jul/2026 a US$99,99/ano).
5. **Vantagens verificáveis do Deadman** `[INTERNO]`: app mobile nativo, check-in biométrico explícito (o Heres depende de atividade on-chain, o que gera falso positivo para quem só faz HODL), check-in sem SOL via Kora, tiers em ordem e vesting.

---

## D. Precificação (resumo; detalhe em `precificacao.md`)

1. [FATO] **Ninguém na categoria cobra porcentagem na liberação ou na saída.** Todos cobram assinatura, quase sempre anual: Cipherwill US$40, Kresus US$99,99, Casa US$250, Nunchuk US$480, Vault12 ~US$360.
2. [ESTIMATIVA] **O plano de US$40/mês só compensa acima de US$96 mil movimentados por ano** (US$84 mil em SKR). Com o mínimo de 12 meses do README, é um compromisso de US$480. Vira produto para baleias.
3. [INTERNO] **A taxa no cancelamento não existe no programa.** Saque, fechamento e revogação são gratuitos on-chain.
4. [FATO] **Custo não é a barreira principal** (17%), atrás de procrastinação (30%), complexidade (24%) e segurança (23%) (CoinCover). Uma taxa de saída aumenta a desconfiança.
5. [ESTIMATIVA] **Simulação de 3 anos:** modelo atual US$6,6K / US$107K / US$731K (conservador / base / otimista); recomendado US$9,7K / US$115K / US$568K, com 7 a 10 vezes mais pagantes. No otimista o atual rende mais, quase tudo pela taxa de cancelamento, que o programa não cobra.
6. [FATO + ESTIMATIVA] **SKR:** as fontes oficiais não falam em burn; o desconto oficial de referência é de 50% no Seeker pago em SKR. O burn de 30% tira ~39% da receita de cada assinante em SKR e equivale a ~0,035% da emissão anual do token: efeito nulo no preço.
7. **Recomendação:** Grátis (0,5% só na liberação, saque grátis, Coercion PIN incluído) + Plus US$79/ano (US$69 em SKR, burn de 0 a 10%), com tiers 3–8, Cloak, vesting e Boney. Testar US$59/79/99 com a waitlist. Não existe pesquisa publicada de disposição a pagar por herança cripto (não encontrado).

---

## E. Posicionamento e mensagem

### E.1 Evidências

- [FATO] Apelo ao medo funciona (d = 0,27) e funciona mais quando vem com **declaração de eficácia** e para comportamentos feitos uma vez (Tannenbaum et al., Psychological Bulletin, 2015; meta-análise de 127 artigos; alta).
- [FATO] Barreiras: procrastinação, complexidade, segurança e confiança, à frente de custo (CoinCover 2026). Nos EUA, 43% dos sem testamento citam procrastinação (Caring.com 2025; média-alta).
- [FATO] A Casa, líder em herança para alto patrimônio, usa tom sóbrio: "Ensure your bitcoin survives you." (casa.io; alta).
- [FATO] A "morte" do mascote da Duolingo (fev/2025) gerou 50,9 bilhões de XP, com o Brasil entre os países que mais contribuíram (NPR, 26/02/2025; alta). Não há dado público de impacto em DAU.
- [FATO] Jameson Lopp (Casa): "There's not much we can definitively state about the effectiveness of duress wallets/triggers, because we have so little data"; o atacante pode escalar (Casa Blog; alta para a citação).

### E.2 Recomendações [ESTIMATIVA]

1. **Dois registros de marca.** Caveira, Boney e "Don't take your crypto to the grave" para o dono cripto-nativo e o dono de Seeker. Tom sóbrio em tudo que o herdeiro vê e no material para alto patrimônio.
2. **Toda frase de medo vem com uma frase de eficácia:** "Don't take your crypto to the grave. One fingerprint a week keeps it with your family."
3. **Trocar "fake wallet"** por "PIN de coação: o app parece normal, o cofre trava e ninguém consegue sacar". Não prometer que o assaltante será enganado. É o que o produto faz (README: "time-lock, not a decoy").
4. **Responder à barreira de confiança antes de escalar:** auditoria publicada, upgrade authority em multisig, taxa travada por plano (hoje o admin pode mudar a taxa até 5% e ela vale para planos existentes `[INTERNO]`).
5. **Boney com regras:** lembrete sim, streak competitivo não; comportamento idêntico na sessão de coação; NFT opcional.

### E.3 Segmentos

| Segmento             | Dor (evidência)                                  | Mensagem                                                                   | Tom           |
| -------------------- | ------------------------------------------------ | -------------------------------------------------------------------------- | ------------- |
| Holder cripto-nativo | adia (30%), complexidade (24%); coação crescendo | "Uma digital por semana. Se você sumir, seus herdeiros recebem, em ordem." | humor negro   |
| Dono de Seeker       | chave já no celular; tem SKR parado              | "A rede de segurança do seu Seeker. Check-in sem gas."                     | nativo, Boney |
| Família / herdeiros  | não sabem que a cripto existe nem como acessar   | "Sua família sabe o que vai receber, e quando." Não substitui testamento   | sóbrio        |
| Alto patrimônio      | confiança (16%) e segurança (23%)                | "Sucessão on-chain que seu advogado consegue auditar."                     | institucional |

### E.4 SWOT [ESTIMATIVA]

- **Forças:** mobile-first; check-in biométrico sem SOL; cobre silêncio, coação e perda; tiers e vesting; marca memorável.
- **Fraquezas:** sem auditoria; admin com chave única para upgrade e taxa; deck e README se contradizem; tom de caveira afasta família.
- **Oportunidades:** dApp Store com 0% de taxa e curadoria "Privacy & Security"; lacuna de planejamento (52%); Brasil com 6,75M em autocustódia; parcerias B2B2C com carteiras e notários.
- **Ameaças:** 30+ protótipos em Solana; carteiras embutindo herança (Kresus, Casa); insegurança jurídica sucessória; rail privado em zona regulatória sensível.

---

## F. Riscos e canais

### F.1 Brasil (hipóteses para advogado de sucessões; não é parecer)

- [FATO] CC art. 1.784 (saisine), arts. 1.789/1.845/1.846 (legítima de 50%), art. 426 (proibição de pacto sucessório), arts. 544/549 (doação a descendente é adiantamento; inoficiosa é nula), art. 1.862 (formas de testamento) (Planalto; alta).
- [FATO] ITCMD progressivo obrigatório (CF art. 155 §1º, VI, EC 132/2023; LC 227/2026, publicada em 14/01/2026, média para a LC).
- [FATO] Lei 14.478/2022 art. 5º: PSAV inclui "custódia ou administração de ativos virtuais ou de instrumentos que possibilitem controle sobre ativos virtuais" (alta).
- [ESTIMATIVA] Riscos: (1) o cofre não afasta a legítima; um tier pode ser reduzido por herdeiros necessários; (2) liberação com o dono vivo é doação, com ITCMD e colação; (3) o produto não dispensa inventário nem imposto, e o rail privado pode parecer ocultação de bens do espólio; (4) enquadramento como PSAV: baixo-médio enquanto a upgrade authority for de chave única. **Aviso obrigatório no material BR:** "complementa, não substitui, testamento e inventário".

### F.2 EUA

- [FATO] RUFADAA cobre ativos guardados por um "custodian"; não resolve chaves em autocustódia (texto final da ULC; alta). Número de estados que adotaram: não verificado.
- [FATO] FinCEN FIN-2019-G001: "total independent control" é o critério; operador de serviço que transmite valor pode ser money transmitter (alta).
- [FATO] Van Loon v. Treasury (5º Circuito, 26/11/2024) distinguiu contratos imutáveis de mutáveis; Roman Storm condenado em 06/08/2025 por operar money transmitting sem licença; fundadores da Samourai condenados em nov/2025 (alta / média).
- [FATO] Exclusão de estate tax US$15M e de gift tax US$19 mil por donatário em 2026 (IRS; alta).
- [ESTIMATIVA] Chave única de upgrade e taxa enfraquece a tese de software não custodial. Rail privado (Cloak) exige termos de uso e marketing sem "esconder herança"; a Cloak faz triagem de sanções via Range antes da camada privada (blog Range, 31/08/2026; média).

### F.3 Segurança percebida `[INTERNO]` + [ESTIMATIVA]

- Sem auditoria e sem verifiable build: limitar depósito por cofre e avisar até a auditoria.
- Bloqueio de coação de até 30 dias pode prolongar um cativeiro se o atacante esperar: comunicar "reduz o ganho do atacante", nunca "te protege do sequestro".
- Guard key no celular roubado permite adiar a herança por até 365 dias: rotação e alerta ao guardião.
- Dependências (Kora, keeper, Cloak): explicar o modo degradado (check-in em SOL; herdeiro executa sozinho).
- Paradas da Solana (5 h em 06/02/2024; média-alta): janelas de 7 ou 30 dias absorvem.

### F.4 Canais

| Prioridade | Canal                      | Fatos                                                                                                                                              | Conf.        | Avaliação [ESTIMATIVA]                                              |
| ---------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | ------------------------------------------------------------------- |
| 1          | Solana dApp Store / Seeker | 0% de taxa sobre compras e assinaturas (docs); 1.561 apps em 25/06/2026; App Spotlight semanal com tema "Privacy & Security" previsto (14/07/2026) | alta / média | Canal do SOM; descoberta depende de curadoria e do CLOCK IN         |
| 2          | Conteúdo PT-BR/EN          | 12 wrench attacks brasileiros na lista do Lopp; engajamento brasileiro com humor de morte (caso Duo)                                               | média        | Educativo para família, humor para o cripto-nativo                  |
| 3          | Superteam / hackathons     | rede ativa no Brasil                                                                                                                               | baixa-média  | Credibilidade e alpha, não volume                                   |
| 4          | Parcerias com carteiras    | Phantom 15M MAU; Casa embute herança                                                                                                               | média        | Maior alavanca e maior ameaça; vender como SDK, depois da auditoria |
| 5          | Notários e advogados       | 38.740 testamentos em 2025 (recorde); US$83,5 tri em transferência de riqueza em 20 anos (Capgemini 2025)                                          | média-alta   | Família e alto patrimônio; exige parecer jurídico                   |
| —          | CAC / conversão por canal  | não encontrado                                                                                                                                     | —            | Medir no alpha                                                      |

---

## Não encontrado / não verificado

- Matéria original da Exame com a Oobit; matéria da "noiva" (06/10/2026).
- Desfecho do pedido de exumação de Gerald Cotten.
- Atualização da Chainalysis sobre BTC perdido depois de 2020.
- Contagem on-chain de Seeker Genesis Tokens (Helius 401).
- Catálogo do dApp Store e busca do Colosseum Arena (páginas em JavaScript).
- Pesquisa publicada de disposição a pagar por herança cripto.
- Burn ou buyback oficial do SKR (só blogs de exchange).
- Política do Google Play para assinatura paga em cripto (necessária antes do lançamento Android).
- Número de estados dos EUA que adotaram a RUFADAA.
- CAC e conversão por canal para apps de herança.
