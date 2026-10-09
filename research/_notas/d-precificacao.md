# Parte D: precificação do Deadman

Notas para o editor-chefe. Pesquisa feita em 2026-10-07. Todas as fontes foram acessadas nessa data. Os preços dos concorrentes foram conferidos nos sites oficiais sempre que possível; quando só havia fonte secundária, isso está marcado.

Convenções:

- **FATO** = conferido em fonte (com confiança alta, média ou baixa).
- **ESTIMATIVA** = conta ou premissa minha, não é dado de mercado.
- Preços de cripto do dia (2026-10-07, API pública CoinGecko + Jupiter): **SOL US$115,65**; **SKR US$0,01616** (as duas fontes batem; market cap US$115,2M; ATH US$0,056). Liquidez do SKR na Jupiter: ~US$652 mil.

---

## 1. Resposta curta

**O modelo atual não fecha bem.** Os três motivos:

1. **O plano de US$40/mês só compensa para quem movimenta mais de US$96 mil por ano.** Abaixo disso, a taxa de 0,5% sai mais barata (ESTIMATIVA: 480 / 0,005 = 96.000; pagando em SKR, 420 / 0,005 = 84.000). Para quase todo usuário do Seeker, assinar não faz sentido financeiro, e o plano vira produto só para "baleias".
2. **US$480/ano está no topo do mercado.** É o preço do plano carro-chefe de herança da Nunchuk (US$480/ano), que vem com multisig assistido e chave de herança dedicada. O concorrente mais parecido com o Deadman (Kresus Inheritance: carteira mobile, Solana, gatilho por inatividade) cobra **US$99,99/ano**. O Cipherwill, citado no deck, cobra **US$40/ano**, não por mês.
3. **A taxa sobre cancelamento é o pior item.** Cobrar para o dono tirar o próprio dinheiro contradiz a promessa de autocustódia e ataca a principal barreira de adoção, que é confiança. Nenhum concorrente pesquisado cobra saída. Ela também **não está implementada no programa on-chain** (ver seção 2).

**O burn de 30% do SKR** queima 30% da receita de quem paga em SKR. Com o volume esperado, isso dá menos de 0,05% da emissão anual de SKR, ou seja, não mexe no token e tira cerca de 39% da receita líquida de cada assinante que paga em SKR (US$24,50 contra US$40).

**Recomendação (detalhe na seção 8):** Grátis, com 0,5% só na liberação e zero no saque ou cancelamento; plano **Plus a US$79/ano** (ou US$8/mês), com desconto de ~13% em SKR, **sem burn ou com burn simbólico de até 10%**, e recursos premium (tiers 3 a 8, entrega privada via Cloak, vesting, Boney customizável) além da taxa zero. O Coercion PIN fica grátis, porque é recurso de segurança e o principal gancho de marketing.

---

## 2. O que o código faz hoje (observação do repo, sem edição)

Li `onchain/programs/deadman/src` só para entender o modelo. Não alterei nada.

- **A taxa só existe na execução.** `split_fee` é chamado em `execute_sol_rule`, `execute_token_rule` e nas liberações de vesting (`release_vested_*`). `withdraw_sol`, `withdraw_token`, `close_vault` e `revoke_vesting` **não cobram taxa**. O "or cancellation" do slide 05 não tem suporte no programa hoje.
- Há taxas separadas por rail (`fee_bps_public` e `fee_bps_private`, Cloak/Zcash), com teto rígido de 5% (`MAX_FEE_BPS = 500`).
- **Como a assinatura isenta a taxa:** num plano de herança, a isenção vale se `paid_until >= last_pulse`. Ou seja, se o dono estava em dia no último check-in, os herdeiros recebem sem taxa, mesmo que a assinatura vença depois. Isso é um bom argumento de venda ("morreu em dia, herdeiro recebe 100%"). Num vesting, a isenção vale se `paid_until >= now`.
- O período padrão da assinatura é de 30 dias, com até 36 períodos por chamada de `subscribe`. **O pré-pagamento anual (12 períodos) já é possível sem mudar o programa.**
- `set_subscription_price` define o preço por mint e um `burn_bps` (0 a 100%) por mint. O burn é configurável e pode ir a 0 sem novo deploy.

---

## 3. Benchmarks de preço

### 3.1 Herança cripto e custódia colaborativa

| Produto                                                                      | Modelo                                                      | Preço conferido                                                                                           | Taxa na liberação?             | Fonte / confiança                                                                                         |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------ | --------------------------------------------------------------------------------------------------------- |
| **Kresus Inheritance** (carteira mobile; Base e Solana segundo a HackerNoon) | Assinatura; beneficiário acessa após período de inatividade | **US$99,99/ano**                                                                                          | Nenhuma mencionada             | Chainwire, 09/07/2026. Alta para o preço. As redes suportadas vêm de fonte secundária (HackerNoon): média |
| **Cipherwill**                                                               | Web app, dead man's switch, guarda chaves e seeds           | Grátis vitalício (limitado) / **Premium US$40/ano** (preço cheio US$60)                                   | Não                            | cipherwill.com/pricing. Alta                                                                              |
| **Casa**                                                                     | Multisig BTC/ETH, herança incluída                          | Standard **US$250/ano**; Premium **US$2.100/ano**; Private Client **US$7.500/ano**                        | Não                            | casa.io/pricing. Alta                                                                                     |
| **Nunchuk**                                                                  | Multisig BTC; herança por timelock                          | Iron Hand US$120/ano (sem herança); **Honey Badger US$480/ano** (herança); Premier US$2.100/ano           | Não                            | nunchuk.io/pricing. Alta                                                                                  |
| **Unchained**                                                                | Vault multisig BTC                                          | Vault **US$250/ano**; Signature US$6.000 no 1º ano, US$4.500 na renovação; Inheritance Boot Camp US$4.000 | Não (há 1% só no trading desk) | unchained.com/pricing. Alta                                                                               |
| **Vault12 Guard**                                                            | App mobile, guardiões (Shamir)                              | Backup US$19,99/mês; **Inheritance US$29,99/mês** (~US$360/ano); 50% de desconto pagando em VGT           | Não                            | vault12.com/pricing e /vgt-subscription. Alta                                                             |
| **Ledger Recover**                                                           | Backup de seed por identidade (não é herança)               | ~US$9,99/mês; a página oficial não mostra o preço (cobra em EUR conforme o país)                          | n/a                            | Preço só em fonte secundária (nobsbitcoin, subger): média                                                 |
| **Bitkey**                                                                   | Herança incluída com o hardware; espera de 6 meses          | Sem taxa separada                                                                                         | Não                            | BusinessWire, 18/11/2024. Alta                                                                            |
| **Inheriti (Safe Haven)**                                                    | Plano vitalício pago em token SHA                           | 10.000 SHA (vitalício); da receita, 50% vai para a fundação, 40% para nós e **10% é queimado**            | Não                            | safehaven.io, 20/05/2022. Média (antigo)                                                                  |
| **Sarcophagus**                                                              | Protocolo on-chain, pago em SARCO                           | Valores não encontrados                                                                                   | Não encontrado                 | não encontrado                                                                                            |
| **Deadhand Protocol**                                                        | A pesquisa anterior dizia "grátis em beta"                  | Não verificado (a página deu 404)                                                                         | não encontrado                 | não encontrado                                                                                            |

### 3.2 Gerenciadores de senha e "legado digital" (âncora de preço do consumidor comum)

| Produto                                                    | Preço                                                         | Herança / acesso de emergência                                                       | Fonte / confiança                                               |
| ---------------------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| **Bitwarden Premium**                                      | **US$19,80/ano** (US$1,65/mês); Families US$47,88/ano         | Emergency Access incluído no Premium                                                 | bitwarden.com/pricing. Alta                                     |
| **1Password Individual**                                   | US$3,99/mês no anual (promo de US$2,99); Families US$5,99/mês | **Não tem** emergency access nativo; recomenda compartilhar um código de recuperação | 1password.com/pricing e fórum oficial 1password.community. Alta |
| **Google Inactive Account Manager / Apple Legacy Contact** | Grátis                                                        | Liberação por inatividade (Google) ou contato de legado (Apple)                      | Fontes secundárias (FTC.net blog, local3news). Média            |

### 3.3 Seguro on-chain (referência para um "prêmio" anual)

| Produto          | Preço                                                                                      | Fonte / confiança                                                                                                               |
| ---------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| **Nexus Mutual** | Cobertura de protocolo de **0,11% a 0,81% ao ano** do valor coberto (exemplos de fev/2025) | Blog da Nexus Mutual, 13/02/2025. Alta. **A pesquisa anterior dizia "2% a 10%". Não confirmei e uso a faixa da fonte oficial.** |

### 3.4 Taxas percentuais aceitas no ecossistema Solana

| Produto                           | Taxa                                               | Fonte / confiança                                                                                                                      |
| --------------------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Phantom (swap/bridge na carteira) | 0,85% (1,5% em swap gasless)                       | Só fontes secundárias (finder, ethereum.org, analyticsinsight). Média                                                                  |
| Squads (multisig)                 | 0,1 SOL de deploy; plano Pro **US$49/mês**         | docs.squads.so/pricing. Alta. (Uma fonte secundária dizia "0,2%, zero no Pro, Pro US$399": **conflita com a doc oficial; use a doc.**) |
| Solana dApp Store                 | **0% de taxa da loja** sobre compras e assinaturas | docs.solanamobile.com (FAQ de publicação). Alta                                                                                        |
| Rede Solana                       | 5.000 lamports por assinatura, metade queimada     | solana.com/docs/core/fees. Alta                                                                                                        |

### 3.5 O que os benchmarks mostram

- **Todo mundo que ganha dinheiro com herança cripto cobra assinatura, quase sempre anual.** Nenhum dos conferidos cobra porcentagem na liberação ou no cancelamento. Deadman seria o único a cobrar saída.
- **Faixas de preço** (FATO, agrupado por mim):
  - Consumidor comum (senhas, legado): US$0 a 50/ano.
  - Herança cripto mobile ou web: **US$40 a 100/ano** (Cipherwill, Kresus).
  - Herança com serviço humano ou multisig assistido: US$250 a 480/ano (Casa, Unchained, Nunchuk Honey Badger, Vault12).
  - Premium com concierge: US$2.000+/ano.
- O Deadman (app mobile, sem hardware nem concierge) a US$480/ano se posiciona como Nunchuk ou Casa sem oferecer o serviço que justifica esse preço.
- **A taxa percentual não é estranha ao usuário Solana** (Phantom cobra 0,85% em swap), mas lá ela é por conveniência numa transação que o usuário escolheu fazer, não um pedágio sobre o próprio saldo.

---

## 4. Disposição a pagar (WTP)

**FATO: não encontrei nenhuma pesquisa publicada que meça quanto o usuário pagaria por herança cripto.** Os dados mais próximos:

| Dado                                             | Valor                                                                                                                                                      | Fonte / data / confiança                                                                                                                                                                                                                                        |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Querem uma solução de herança cripto             | **78%**                                                                                                                                                    | Coincover/Censuswide, "The Crypto Inheritance Black Hole". 2.000 adultos do Reino Unido, 35 a 50 anos, com autocustódia e mais de US$10 mil em cripto. Data do relatório não confirmada (o metadado do PDF diz 02/07/2026). Alta para o dado, média para a data |
| Não têm plano de herança para cripto             | **52%**                                                                                                                                                    | Mesma fonte                                                                                                                                                                                                                                                     |
| Barreiras para não planejar                      | "Não priorizei" 30%; "complexo demais" 24%; "medo de segurança" 23%; "não sei o jeito certo" 22%; **"custo" 17%**; **"não confio em nenhum provedor" 16%** | Mesma fonte, Q13. **Custo está atrás de complexidade, segurança e confiança**                                                                                                                                                                                   |
| Preocupados com o destino da cripto após a morte | 89% (1.150 entrevistados, out/2019 a jun/2020)                                                                                                             | Cremation Institute via Cointelegraph, 08/07/2020. Média (antigo, amostra não probabilística)                                                                                                                                                                   |
| Conversão de apps de assinatura                  | Freemium: **~2,1%** de trial para pago no D35; paywall rígido: ~10,7%                                                                                      | RevenueCat, State of Subscription Apps 2026 (19/03/2026). Alta para a mediana do mercado geral; não é específico de cripto                                                                                                                                      |
| Retenção de 12 meses (planos mensais)            | ~6% a 11% (mediana por faixa de preço)                                                                                                                     | RevenueCat SOSA 2026. Média: a página resume por faixa de preço, e um blog cita 17%                                                                                                                                                                             |
| Churn involuntário no Google Play                | 31% dos cancelamentos                                                                                                                                      | RevenueCat 2026. Média                                                                                                                                                                                                                                          |

**ESTIMATIVA de WTP (premissas explícitas):**

- Ancoragem: o usuário compara com o que conhece. Senhas custam ~US$20/ano, Cipherwill US$40, Kresus US$100 e o próprio Seeker ~US$450 a 500. Um Deadman a US$480/ano custa o preço do celular por ano.
- Faixa plausível para o usuário mediano do Seeker: **US$50 a 100/ano**. Acima de US$250, só quem tem saldo grande, e esse público já tem Casa, Nunchuk e Unchained com serviço humano.
- Como "custo" pesa menos que "confiança" e "complexidade" (Coincover), **reduzir atrito vale mais que cortar preço**: a taxa sobre cancelamento aumenta atrito e desconfiança.
- **Validar com teste real:** oferecer US$59, US$79 e US$99/ano aos 52 da waitlist e aos 10 do alpha (Van Westendorp simples ou três links de checkout).

---

## 5. Economia por usuário (ESTIMATIVA)

| Item                                                                                | Conta                                                   | Resultado                                                                                                                                                                                                                     |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Break-even do plano mensal (US$40) contra a taxa de 0,5%                            | 480 / 0,005                                             | Só compensa acima de **US$96.000/ano** liberados ou sacados                                                                                                                                                                   |
| Break-even pagando em SKR (US$35)                                                   | 420 / 0,005                                             | Acima de **US$84.000/ano**                                                                                                                                                                                                    |
| Break-even do plano recomendado (US$79/ano)                                         | 79 / 0,005                                              | Acima de **US$15.800/ano**                                                                                                                                                                                                    |
| Receita da taxa por usuário típico (cofre de US$1.500; 5% liberado/ano)             | 1.500 × 5% × 0,5%                                       | **~US$0,38/ano**. Mesmo somando 30% de saque/ano: ~US$2,60/ano                                                                                                                                                                |
| Exemplo do deck (1 SOL)                                                             | 0,005 SOL × US$115,65                                   | **~US$0,58 por liberação**                                                                                                                                                                                                    |
| Custo de patrocinar um check-in (Kora paga a taxa; 2 assinaturas; sem priority fee) | 10.000 lamports × US$115,65/SOL                         | ~US$0,0012 por check-in; **~US$0,06/usuário/ano** com check-in semanal. Não inclui rent nem priority fee                                                                                                                      |
| Taxa de morte (referência para liberação "por silêncio real")                       | Tabela atuarial SSA (EUA): homem de 35 anos ≈ 0,26%/ano | Média (valor de busca; o site da SSA bloqueou o acesso direto). **Mortes geram pouquíssimas liberações nos 3 primeiros anos. A taxa na execução vai depender de vesting e de silêncios não ligados a morte, não de herança.** |

Conclusão: **a taxa de 0,5% não sustenta o negócio no curto prazo.** Só a taxa sobre cancelamento produz volume relevante, e é justamente o item que mais afasta usuários.

---

## 6. Simulação de receita, 3 anos (out/2026 a set/2029)

Script reproduzível (ESTIMATIVA): `research/_notas/d-precificacao-sim.py` (rode com `python3 d-precificacao-sim.py`). É um modelo mensal; usuários crescem linearmente dentro de cada ano, a partir dos 10 do alpha.

### 6.1 Premissas (todas são ESTIMATIVAS minhas)

| Premissa                                                     | Conservador         | Base                   | Otimista                | Justificativa                                                                                                                                                  |
| ------------------------------------------------------------ | ------------------- | ---------------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Usuários com cofre ativo (fim do ano 1 / 2 / 3)              | 300 / 1.500 / 4.000 | 1.000 / 6.000 / 20.000 | 3.000 / 20.000 / 60.000 | Ano 1 só no Seeker. ~72 mil carteiras resgataram o airdrop de SKR (FATO, Solana Mobile), então 1.000 usuários ≈ 1,4% delas. Android a partir de meados de 2027 |
| Saldo médio no cofre                                         | US$500              | US$1.500               | US$3.000                | Sem dado público. O alpha passou 200+ SOL em 10 usuários (~US$2.300 cada, mas é fluxo de teste, não saldo)                                                     |
| Churn mensal de usuários (fecham o cofre)                    | 4%                  | 3%                     | 2%                      | —                                                                                                                                                              |
| % do saldo liberado por ano (herança, silêncio, vesting)     | 3%                  | 5%                     | 8%                      | Mortalidade de ~0,1 a 0,3%/ano; o resto vem de vesting e silêncios sem morte                                                                                   |
| % do saldo sacado ou cancelado por ano                       | 25%                 | 30%                    | 30%                     | Cofre usado como "reserva", com saques frequentes                                                                                                              |
| Pagantes guardam X vezes o saldo médio                       | 5×                  | 5×                     | 5×                      | Quem assina é quem tem mais saldo (efeito do break-even)                                                                                                       |
| % dos assinantes que pagam em SKR                            | 50%                 | 40%                    | 30%                     | —                                                                                                                                                              |
| **Modelo atual:** conversão de novos usuários para US$40/mês | 0,5%                | 1,5%                   | 3%                      | Abaixo do freemium mediano de 2,1% (RevenueCat), porque o break-even é de US$96 mil                                                                            |
| **Modelo atual:** churn mensal de assinantes                 | 18%                 | 14%                    | 10%                     | RevenueCat: retenção de 12 meses de planos mensais entre ~6% e 17%                                                                                             |
| **Recomendado:** conversão para US$79/ano                    | 2%                  | 5%                     | 8%                      | Perto ou acima da mediana freemium, porque há recursos exclusivos e o preço é mais baixo                                                                       |
| **Recomendado:** renovação anual                             | 30%                 | 45%                    | 60%                     | RevenueCat: dados conflitantes sobre retenção anual (28% a 44%)                                                                                                |

### 6.2 Resultados (US$, receita bruta, sem impostos nem custos)

**Modelo ATUAL** (0,5% na execução e no cancelamento; US$40/mês, ou US$35 em SKR com 30% queimado):

| Cenário     | Ano 1  | Ano 2   | Ano 3   | Total 3 anos | Pagantes no fim do ano 3 | Fatia da taxa de cancelamento no ano 3 | Valor queimado no ano 3 |
| ----------- | ------ | ------- | ------- | ------------ | ------------------------ | -------------------------------------- | ----------------------- |
| Conservador | 318    | 1.675   | 4.610   | **6.604**    | 9                        | 1.763 (38%)                            | 429                     |
| Base        | 3.676  | 23.261  | 79.925  | **106.862**  | 151                      | 29.294 (37%)                           | 5.685                   |
| Otimista    | 24.073 | 169.840 | 537.155 | **731.068**  | 1.006                    | 170.461 (32%)                          | 28.625                  |

**Modelo RECOMENDADO** (0,5% só na liberação; zero no cancelamento; US$79/ano, ou US$69 em SKR, sem burn):

| Cenário     | Ano 1  | Ano 2   | Ano 3   | Total 3 anos | Pagantes no fim do ano 3 |
| ----------- | ------ | ------- | ------- | ------------ | ------------------------ |
| Conservador | 542    | 2.602   | 6.533   | **9.677**    | 86                       |
| Base        | 4.487  | 26.159  | 84.323  | **114.970**  | 1.074                    |
| Otimista    | 21.314 | 139.682 | 407.273 | **568.268**  | 4.972                    |

### 6.3 Leitura honesta dos números

- No conservador e no base, **o modelo recomendado empata ou rende mais**, com 7 a 10 vezes mais pagantes (base mais diversificada e menos dependente de baleias).
- **No otimista, o modelo atual rende ~29% mais**, quase todo o ganho vindo da taxa de cancelamento (US$170 mil no ano 3). O modelo não captura o efeito contrário: tirar o pedágio de saída deve aumentar depósitos e adesão. Para empatar no otimista, o recomendado precisaria de ~30% mais saldo ou usuários. Isso é plausível, mas não está provado.
- **Em todos os cenários a receita é pequena nos 3 anos** (US$10 mil a 730 mil). O preço não muda isso; o que muda é distribuição (Seeker, Android, B2B ou SDK para carteiras).
- A pesquisa anterior (`~/Downloads/precificacao-deadman.md`) falava em "~10 mil Seekers". **Isso conflita com a Solana Mobile**: "mais de 150.000 dispositivos" no post do SKR, e ~72 mil carteiras resgataram o airdrop. Use 150 mil para dispositivos vendidos e ~72 mil como proxy de usuários ativos.

---

## 7. Desconto e burn de 30% do SKR

### 7.1 O que a Solana Mobile diz sobre o SKR (FATO)

- O SKR é "the native asset of the Solana Mobile ecosystem" e "distributes control, powers curation, and aligns incentives". Suprimento total de 10 bilhões: 30% airdrops, 25% crescimento e parcerias, 10% tesouro da comunidade, 15% Solana Mobile, 10% Solana Labs, 10% liquidez. Alta.
- **Inflação de staking:** começa em 10%, cai 25% ao ano até 2% terminal, linear. Staking delegado a "Guardians" (que verificam dispositivos e fazem a curadoria da dApp Store), épocas de 2 dias, cooldown de 48h. A página do SKR mostrava ~16,4% de yield e 4,93B de SKR em stake. Alta.
- **Lançamento:** airdrop em 21/01/2026. "1.8 billion SKR distributed to almost 72,000 wallets", e mais de 40% do resgatado foi para stake (guia oficial). Alta.
- **Pagamento em SKR com desconto:** 50% de desconto no Seeker pago em SKR, até 21/02/2026 (guia oficial). Alta. **É o precedente oficial de "pague em SKR e ganhe desconto".**
- **Burn ou buyback:** **as fontes oficiais (docs, página do SKR, blog) não mencionam burn.** Blogs de exchanges (KuCoin, Mobee) afirmam que parte das taxas da dApp Store recompra e queima SKR. **Não confirmei em fonte primária. Confiança baixa; não usar.**
- **Pagamentos e assinaturas em SKR:** as fontes oficiais não descrevem esse uso. Só fontes secundárias falam em "in-app purchases, subscriptions". Baixa.
- A dApp Store não cobra taxa sobre assinaturas. Alta.

### 7.2 Precedentes de desconto e burn

| Caso                  | O que faz                                                               | Token próprio ou de terceiro?   | Fonte / confiança                                                                                                   |
| --------------------- | ----------------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Vault12               | 50% de desconto pagando em VGT                                          | Próprio                         | vault12.com, 08/05/2025. Alta                                                                                       |
| Inheriti / Safe Haven | 10% do pagamento em SHA é queimado                                      | Próprio                         | safehaven.io, 2022. Média                                                                                           |
| BONKbot               | Taxa de 1% por trade; uma parte (~10% das taxas) recompra e queima BONK | **Terceiro** (ecossistema BONK) | Só fontes secundárias (Blockworks Research, coincodecap). O relatório da Blockworks em PDF não pôde ser lido. Média |
| Solana Mobile         | 50% de desconto no Seeker pago em SKR                                   | Próprio                         | Guia oficial do SKR. Alta                                                                                           |
| Rede Solana           | 50% da taxa base é queimada                                             | Nativo                          | solana.com/docs. Alta                                                                                               |

O BONKbot é o precedente mais próximo de um app queimar token de outro projeto. Lá, porém, o burn é uma fatia pequena (~10% das taxas) e o app nasceu dentro da marca BONK. **Não achei nenhum app do ecossistema Seeker que queime SKR com receita própria.**

### 7.3 Impacto do burn de 30% (ESTIMATIVA)

- **Para a receita:** um assinante em SKR rende US$35 × 70% = **US$24,50 líquido**, contra US$40 em SOL ou USDC (−39%). Pela simulação base, o burn custa ~US$5,7 mil no ano 3; no otimista, ~US$28,6 mil.
- **Para o SKR:** o market cap é de ~US$115M. A emissão do ano 1 é de ~10% de 10B = ~1B de SKR ≈ US$16M/ano a US$0,0162. Os US$5,7 mil do base equivalem a **~0,035% da emissão anual**. **Efeito no preço: nulo.** O burn é só marketing.
- **Riscos:**
  - Volatilidade: o SKR está ~71% abaixo do ATH (US$0,056 → US$0,0162), e a receita em SKR perde valor se não for convertida.
  - Liquidez baixa: ~US$652 mil na Jupiter, o que dá slippage ao vender SKR do tesouro.
  - Percepção de "tokenomics de fachada" por parte de investidores.
  - Risco regulatório pequeno, mas real, ao associar a receita a mexer no preço de um token de terceiro (não verificado com advogado).
  - O preço em SKR é fixado on-chain em unidades de token (`price_per_period`). Se o SKR subir ou cair, o "US$35" muda. **Precisa de reprecificação periódica** (já existe `tool/set_subscription_price.dart`).
- **Pontos positivos:** alinhamento com a Solana Mobile, chance de destaque na dApp Store ou em temporadas Seeker, e uso para o SKR do airdrop parado na carteira (~72 mil carteiras).

**Veredito:** manter o pagamento em SKR com **desconto moderado (10 a 15%)**. **Cortar o burn para 0 a 10%**, tratado como custo de marketing (o `burn_bps` é configurável por mint). Se quiser um gesto ao ecossistema, é mais eficaz fazer stake do SKR recebido num Guardian ou propor co-marketing à Solana Mobile do que queimar.

---

## 8. A taxa sobre cancelamento afasta usuários?

**Sim, na minha avaliação** (ESTIMATIVA baseada nos dados abaixo; não há estudo específico):

- **Vai contra a proposta:** o deck vende autocustódia ("~60% preferem autocustódia"). Cobrar para o dono mexer no próprio dinheiro é o que um usuário de autocustódia rejeita.
- **Confiança e segurança são as barreiras principais:** 23% citam medo de segurança e 16% não confiam em provedores, contra 17% que citam custo (Coincover). Um pedágio de saída aumenta a desconfiança.
- **Nenhum concorrente cobra saída** (seção 3).
- **Cria um incentivo ruim:** o usuário evita depositar tudo (deposita menos para "testar"), e o saldo protegido, que é a métrica de tração do deck, encolhe.
- **Não está no programa:** saque, fechar cofre e revogar vesting são gratuitos on-chain. O slide promete algo que o produto não faz.
- O ganho de receita existe (32 a 38% da receita nos cenários do modelo atual), mas é exatamente o tipo de receita que trava a adoção.

Se for preciso cobrir custo de saída, a alternativa é uma **taxa fixa pequena para cobrir o custo** (ex.: 0,001 SOL ≈ US$0,12), e não uma porcentagem.

---

## 9. Estrutura de preço recomendada

| Plano                                   | Preço                                                                | O que inclui                                                                                                                    | Taxa na liberação                                                        | Saque / cancelamento |
| --------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ | -------------------- |
| **Grátis**                              | US$0                                                                 | 1 cofre, até 2 tiers, entrega pública (Solana), check-in patrocinado (Kora), **Coercion PIN**                                   | **0,5%** (opcional: teto por liberação, ex. US$250)                      | **Grátis**           |
| **Plus**                                | **US$79/ano** (ou US$8/mês); **US$69/ano em SKR** (~13% de desconto) | Até 8 tiers, entrega privada via Cloak, vesting, janelas personalizadas, Boney customizável, vários cofres, aviso aos herdeiros | **0%** (herdeiro recebe 100% se o dono estava em dia no último check-in) | Grátis               |
| **Pro / Família** (depois da auditoria) | US$199 a 249/ano                                                     | Vários cofres e famílias, suporte na hora do herdeiro receber                                                                   | 0%                                                                       | Grátis               |

Justificativa:

1. **US$79/ano** fica entre o Cipherwill (US$40) e o Kresus (US$99,99), os comparáveis mais diretos, e bem abaixo da faixa com serviço humano (US$250+). Cabe na WTP estimada de US$50 a 100.
2. **Cobrança anual primeiro.** Em Solana não há débito automático, então a renovação mensal depende do usuário lembrar. O RevenueCat mostra retenção muito baixa em planos mensais. O programa já aceita 12 a 36 períodos por chamada.
3. **O plano vende recursos, não só taxa zero.** Com taxa zero como único benefício, o break-even exige movimentar US$15,8 mil/ano a US$79, e quase ninguém chega lá. Com Cloak, vesting e tiers extras, a decisão deixa de ser só aritmética.
4. **O Coercion PIN fica grátis:** é recurso de segurança física (o deck cita alta dos wrench attacks), é o diferencial que mais gera conversa, e cobrar por ele teria ônus ético e de imagem.
5. **0,5% só na liberação** continua alinhado ao discurso "só cobramos quando entregamos" e ao demo do slide 03 (1 SOL → 0,995). Um teto opcional por liberação protege contra a objeção de baleias.
6. **SKR com desconto e sem burn (ou burn de até 10%):** preserva a receita e mantém o alinhamento com o ecossistema.

**Riscos e incertezas desta recomendação:**

- Nenhum preço foi testado com usuário real. Testar US$59, 79 e 99 com a waitlist antes de travar.
- A loja Android fora do Seeker (Google Play, meados de 2027) pode exigir billing próprio e taxa de 10 a 15% sobre assinaturas digitais. **Não verifiquei a política do Google Play para pagamento em cripto**; checar antes do lançamento Android.
- Vender como "seguro" exigiria licença (ex.: SUSEP no Brasil). Essa é uma inferência da pesquisa anterior, não verificada; evitar a palavra "seguro" no material.

---

## 10. Re-verificação da pesquisa anterior (`~/Downloads/precificacao-deadman.md`)

| Afirmação anterior                                       | Status em 2026-10-07                                                                                         |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Casa Standard US$250 / Premium US$2.100                  | **Confirmado** (casa.io). Existe também o Private Client a US$7.500                                          |
| Unchained US$250/ano; Signature US$4.500                 | **Confirmado** (US$4.500 na renovação; US$6.000 no 1º ano)                                                   |
| Nunchuk US$120 / 480 / 2.100                             | **Confirmado**                                                                                               |
| Vault12 US$19,99 / 29,99 por mês; 50% de desconto em VGT | **Confirmado**                                                                                               |
| Ledger Recover US$9,99/mês, até US$50 mil de compensação | Compensação confirmada (página oficial, via Coincover). Preço só em fonte secundária: média                  |
| Bitkey: herança incluída no hardware                     | **Confirmado**                                                                                               |
| Safe Haven: "fonte não dá valores"                       | **Corrigido:** 10.000 SHA (vitalício), 10% queimado                                                          |
| Nexus Mutual "~2% a 10% ao ano"                          | **Não confirmado.** A fonte oficial (fev/2025) dá 0,11% a 0,81% ao ano                                       |
| "~10 mil Seekers"                                        | **Conflita** com a Solana Mobile (150 mil+ dispositivos; ~72 mil carteiras no airdrop)                       |
| "Ninguém cobra porcentagem na liberação"                 | **Confirmado** nos produtos conferidos                                                                       |
| Deadhand grátis em beta                                  | Não verificado (404)                                                                                         |
| Recomendação de 2% com teto de US$250 no grátis          | **Discordo de 2%:** 0,5% já é o número do deck e do demo; 2% assusta. O teto é uma boa ideia                 |
| Keeper a US$49/ano                                       | Faixa coerente; recomendo US$79 por causa do Kresus e porque o plano inclui recursos premium. Testar as duas |

---

## 11. Tabela de fontes

| #   | Título                                                                       | URL                                                                                                                          | Data da fonte                                             | Acesso                                                | Confiança                                                                                                            |
| --- | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| 1   | Cipherwill – Pricing                                                         | https://www.cipherwill.com/pricing                                                                                           | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 2   | Casa – Pricing                                                               | https://casa.io/pricing                                                                                                      | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 3   | Nunchuk – Pricing                                                            | https://nunchuk.io/pricing                                                                                                   | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 4   | Unchained – Pricing                                                          | https://www.unchained.com/pricing                                                                                            | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 5   | Vault12 – Pricing                                                            | https://vault12.com/pricing/                                                                                                 | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 6   | Vault12 – VGT subscription discount                                          | https://vault12.com/vgt-subscription                                                                                         | 2025-05-08                                                | 2026-10-07                                            | Alta                                                                                                                 |
| 7   | Kresus Inheritance (press release, Chainwire)                                | https://chainwire.org/2026/07/09/kresus-pioneers-crypto-inheritance-and-legacy-planning-for-wealth-across-generations/       | 2026-07-09                                                | 2026-10-07                                            | Alta                                                                                                                 |
| 8   | HackerNoon – Kresus (redes Base e Solana)                                    | https://hackernoon.com/who-inherits-your-bitcoin-when-you-die-kresus-wants-an-answer-built-into-the-wallet                   | 2026                                                      | 2026-10-07                                            | Média                                                                                                                |
| 9   | Ledger Recover (página oficial)                                              | https://shop.ledger.com/pages/ledger-recover                                                                                 | página atual                                              | 2026-10-07                                            | Alta (sem preço)                                                                                                     |
| 10  | No BS Bitcoin – Ledger Recover US$9,99/mês                                   | https://nobsbitcoin.com/ledger-launched-its-recover-service                                                                  | 2023                                                      | 2026-10-07                                            | Média                                                                                                                |
| 11  | Bitkey inheritance (BusinessWire)                                            | https://www.businesswire.com/news/home/20241118370113/en                                                                     | 2024-11-18                                                | 2026-10-07                                            | Alta                                                                                                                 |
| 12  | Safe Haven – Utility rewards distribution                                    | https://safehaven.io/dr8d                                                                                                    | 2022-05-20                                                | 2026-10-07                                            | Média                                                                                                                |
| 13  | Bitwarden – Pricing                                                          | https://bitwarden.com/pricing/                                                                                               | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 14  | 1Password – Pricing                                                          | https://1password.com/pricing/password-manager                                                                               | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 15  | 1Password Community – Access after death / Legacy contacts                   | https://www.1password.community/1password-at-home-31/feature-request-1password-access-after-death-legacy-contacts-1114       | thread em aberto                                          | 2026-10-07                                            | Alta                                                                                                                 |
| 16  | FTC.net – Digital legacy planning (Google/Apple grátis)                      | https://www.ftc.net/blog/digital-legacy-planning-for-after-youre-gone/                                                       | sem data                                                  | 2026-10-07                                            | Média                                                                                                                |
| 17  | Nexus Mutual – Lower price, same cover                                       | https://nexusmutual.io/blog/lower-price-same-industry-leading-cover                                                          | 2025-02-13                                                | 2026-10-07                                            | Alta                                                                                                                 |
| 18  | Squads – Pricing                                                             | https://docs.squads.so/main/getting-started/pricing.md                                                                       | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 19  | Squads – Costs of using Squads                                               | https://docs.squads.so/main/additional-resources/costs-of-using-squads                                                       | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 20  | Phantom 0,85% (review secundária)                                            | https://www.finder.com.au/cryptocurrency/wallets/phantom-wallet-review                                                       | 2026                                                      | 2026-10-07                                            | Média                                                                                                                |
| 21  | Solana Docs – Fees                                                           | https://solana.com/docs/core/fees.md                                                                                         | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 22  | Solana Mobile – dApp publishing Q&A (0% de taxa)                             | https://docs.solanamobile.com/dapp-publishing/qanda                                                                          | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 23  | Solana Mobile Docs – SKR                                                     | https://docs.solanamobile.com/solana-mobile-stack/skr                                                                        | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 24  | Solana Mobile – SKR page (staking, Guardians, yield)                         | https://solanamobile.com/skr                                                                                                 | página atual                                              | 2026-10-07                                            | Alta                                                                                                                 |
| 25  | Solana Mobile – SKR launches January 2026 (150K+ dispositivos, distribuição) | https://solanamobile.com/blog/skr-launches-january-2026                                                                      | data exibida 2026-07-14 (conteúdo anterior ao lançamento) | 2026-10-07                                            | Alta para o conteúdo; média para a data                                                                              |
| 26  | Solana Mobile – Your guide to SKR (72 mil carteiras; 50% off pagando em SKR) | https://solanamobile.com/blog/your-skr-guide                                                                                 | data exibida 2026-07-14                                   | 2026-10-07                                            | Alta                                                                                                                 |
| 27  | The Block – SKR airdrop                                                      | https://www.theblock.co/post/386449/solana-mobile-seeker-skr-token-airdrop                                                   | 2026-01-20                                                | 2026-10-07                                            | Alta                                                                                                                 |
| 28  | CoinGecko API – preço do SKR                                                 | https://api.coingecko.com/api/v3/simple/price?ids=seeker&vs_currencies=usd&include_market_cap=true                           | 2026-10-07                                                | 2026-10-07                                            | Alta (valor do dia)                                                                                                  |
| 29  | Jupiter Price API v3 – SKR e SOL (inclui liquidez)                           | https://lite-api.jup.ag/price/v3?ids=SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3,So11111111111111111111111111111111111111112 | 2026-10-07                                                | 2026-10-07                                            | Alta (valor do dia)                                                                                                  |
| 30  | The Block – preço do SKR                                                     | https://www.theblock.co/price/seeker                                                                                         | 2026-10-07                                                | 2026-10-07                                            | Alta. Um snippet de busca dizia US$0,0065 / US$43,9M, o que **conflita**; prevalecem CoinGecko e Jupiter (US$0,0162) |
| 31  | KuCoin blog – SKR buyback/burn (não confirmado)                              | https://www.kucoin.com/blog/en-what-is-seeker-skr-the-rise-of-solana-s-mobile-first-economy                                  | 2026                                                      | 2026-10-07                                            | Baixa                                                                                                                |
| 32  | Blockworks Research – BONK flywheel (BONKbot burn)                           | https://app.blockworksresearch.com/unlocked/bonk_from-memecoin-to-utility-flywheel                                           | 2025/2026                                                 | 2026-10-07 (não carregou; dado via busca)             | Média                                                                                                                |
| 33  | Coincover – The Crypto Inheritance Black Hole (PDF)                          | https://www.coincover.com/hubfs/The%20Crypto%20Inheritance%20Black%20Hole%20Report%20-%20CoinCover.pdf                       | não confirmada (metadado 2026-07-02)                      | 2026-10-07                                            | Alta (dados); média (data)                                                                                           |
| 34  | Cointelegraph – Study: 89% worry (Cremation Institute)                       | https://cointelegraph.com/news/study-89-worry-what-happens-to-their-crypto-after-they-die                                    | 2020-07-08                                                | 2026-10-07                                            | Média                                                                                                                |
| 35  | RevenueCat – Subscription app trends & benchmarks 2026                       | https://www.revenuecat.com/blog/growth/subscription-app-trends-benchmarks-2026.md                                            | 2026-03-19                                                | 2026-10-07                                            | Alta                                                                                                                 |
| 36  | RevenueCat – SOSA 2026 insights                                              | https://revenuecat.com/sosa-26-insights/                                                                                     | 2026                                                      | 2026-10-07                                            | Média                                                                                                                |
| 37  | SSA – Actuarial Life Table (mortalidade aos 35)                              | https://www.ssa.gov/oact/STATS/table4c6.html                                                                                 | tabela de 2022/2023                                       | 2026-10-07 (acesso direto bloqueado, valor via busca) | Média                                                                                                                |
| 38  | Mobile ID World – Seeker envia 150 mil pré-vendas                            | https://mobileidworld.com/solana-mobile-ships-seeker-web3-smartphone-with-150000-global-pre-orders/                          | 2025-08                                                   | 2026-10-07                                            | Média                                                                                                                |
| 39  | Blockeden – Kora (Solana Foundation, abr/2026)                               | https://blockeden.xyz/blog/2026/04/22/solana-kora-signing-node-fee-relayer-gasless-ux-primitive/                             | 2026-04-22                                                | 2026-10-07                                            | Média                                                                                                                |
| 40  | Código do Deadman (taxas, assinatura, burn)                                  | `onchain/programs/deadman/src/{constants,state}.rs`, `instructions/{funds,subscription}.rs`                                  | working tree de 2026-10-07                                | 2026-10-07                                            | Alta                                                                                                                 |
