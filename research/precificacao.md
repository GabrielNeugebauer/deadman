# Precificação do Deadman

> **Histórico (2026-10-08):** o dono decidiu outro modelo. Não há mais assinatura (Plus). A taxa é 2% só na liberação, ou 1,5% quando o pagamento é em $SKR, com 10% dessa taxa em SKR queimados on-chain. Saques, fechamento e revogação continuam grátis.

Data de corte: 2026-10-07. Fontes completas em [`fontes.md`](fontes.md); notas de origem em [`_notas/d-precificacao.md`](_notas/d-precificacao.md). A simulação é reproduzível com `python3 research/_notas/d-precificacao-sim.py` (o editor rodou de novo em 2026-10-07 e os números abaixo batem).

Marcas: **[FATO]** conferido em fonte; **[ESTIMATIVA]** conta ou premissa nossa; **[INTERNO]** código ou README do repositório.

Preços de referência do dia [FATO, CoinGecko e Jupiter, 2026-10-07, não reverificados pelo editor: confiança média]: SOL US$115,65; SKR US$0,0162 (~71% abaixo da máxima de US$0,056); liquidez do SKR na Jupiter ~US$652 mil.

---

## 1. Resposta curta

O modelo atual (0,5% na execução ou no cancelamento, ou US$40/mês com 0% de taxa, US$35 em SKR com 30% queimado) tem quatro problemas:

1. **O plano quase nunca compensa para o usuário.** [ESTIMATIVA] 480 / 0,005 = US$96 mil movimentados por ano para empatar com a taxa (US$84 mil pagando em SKR). O README ainda exige mínimo de 12 meses `[INTERNO]`.
2. **US$480/ano é preço de topo de mercado** sem o serviço que o justifica. [FATO] É o preço do Nunchuk Honey Badger, que inclui multisig assistido e chave de herança dedicada.
3. **A taxa no cancelamento contradiz a autocustódia e não existe no programa.** `[INTERNO]` `split_fee` só roda em `execute_*_rule` e `release_vested_*`.
4. **O burn de 30% custa receita e não move o token** (seção 5).

**Recomendação:** Grátis com 0,5% só na liberação e saque sempre grátis; **Plus a US$79/ano** (US$69 em SKR, burn de 0 a 10%), vendendo recursos e não só taxa zero. Testar US$59/79/99 com a waitlist antes de fixar.

---

## 2. Benchmarks [FATO]

### 2.1 Herança cripto

| Produto               | Preço                                                                 | Equivalente anual | Taxa na liberação/saída     | Plataforma / Solana                           | Fonte (data) · confiança                       |
| --------------------- | --------------------------------------------------------------------- | ----------------- | --------------------------- | --------------------------------------------- | ---------------------------------------------- |
| Heres Protocol        | US$2 de criação + US$2/mês por cápsula                                | ~US$26 no 1º ano  | não (doc: "None")           | web; Solana devnet                            | heresprotocol.com/pricing · alta               |
| Cipherwill            | grátis / Premium US$40/ano (de US$60)                                 | US$40             | não                         | PWA; indireto                                 | cipherwill.com/pricing · alta                  |
| Kresus Inheritance    | US$99,99/ano                                                          | US$100            | nenhuma mencionada          | carteira; Solana segundo a HackerNoon (média) | Chainwire, 09/07/2026 · alta                   |
| Casa                  | Standard US$250; Premium US$2.100; Private Client US$7.500            | US$250–7.500      | não                         | iOS/Android/web; sem Solana                   | casa.io/pricing · alta                         |
| Unchained             | Vault US$250/ano; Signature US$6.000 (1º ano)                         | US$250–6.000      | não (1% só no trading desk) | só BTC                                        | unchained.com/pricing · alta                   |
| Vault12 Guard         | Inheritance US$29,99/mês; 50% off em VGT                              | ~US$360           | não                         | iOS/Android; seeds incl. SOL                  | vault12.com/pricing · alta                     |
| Nunchuk               | Iron Hand US$120 (sem herança); Honey Badger US$480; Premier US$2.100 | US$480 (herança)  | não                         | só BTC                                        | nunchuk.io/pricing · alta                      |
| Ledger Recover        | ~US$9,99/mês                                                          | ~US$120           | n/a                         | Ledger                                        | imprensa, 2023 · média                         |
| Bitkey                | herança incluída no hardware de US$250                                | —                 | não                         | só BTC                                        | BusinessWire, 18/11/2024 · alta                |
| Inheriti (Safe Haven) | €39,99 (Inheritance), exige SHA; 10% da receita em SHA queimada       | único             | não                         | sem Solana                                    | inheriti.com · alta; safehaven.io 2022 · média |
| DMV (Seeker)          | 0,01 SOL                                                              | ~US$1             | não                         | Android; Solana devnet                        | GitHub Romulus-Sol/DMV · alta                  |
| BSafe                 | grátis com 1% no claim; Premium 1 SOL; Concierge 50 SOL/ano           | —                 | **1% no claim**             | web; Solana devnet                            | GitHub Plague14/bsafe · alta                   |

### 2.2 Âncoras de consumo

| Produto                                                | Preço                          | Fonte · confiança               |
| ------------------------------------------------------ | ------------------------------ | ------------------------------- |
| Bitwarden Premium (Emergency Access)                   | US$19,80/ano                   | bitwarden.com/pricing · alta    |
| 1Password Individual                                   | US$3,99/mês (anual)            | 1password.com/pricing · alta    |
| Google Inactive Account Manager / Apple Legacy Contact | grátis                         | secundárias · média             |
| Nexus Mutual (cobertura)                               | 0,11% a 0,81% ao ano           | blog oficial, 13/02/2025 · alta |
| Phantom (swap)                                         | 0,85%                          | secundárias · média             |
| Solana dApp Store                                      | 0% sobre compras e assinaturas | docs.solanamobile.com · alta    |

### 2.3 Leitura

- Faixas [FATO agrupado por nós]: consumo comum US$0–50/ano; herança cripto web/mobile **US$40–100/ano**; herança com serviço humano ou multisig assistido US$250–480/ano; concierge US$2.000+.
- Entre os produtos lançados, **ninguém cobra porcentagem na saída**. Entre protótipos de hackathon, o BSafe cobra 1% no claim (beneficiário), não no saque do dono.
- O Deadman a US$480/ano fica no nível do Nunchuk e acima da Casa, sem hardware, multisig assistido nem concierge.

---

## 3. Disposição a pagar

- [FATO] **Não existe pesquisa publicada que meça disposição a pagar por herança cripto** (não encontrado).
- [FATO] 78% querem uma solução; 52% não têm plano. Barreiras: "não priorizei" 30%, complexidade 24%, segurança 23%, "não sei o jeito certo" 22%, **custo 17%**, **"não confio em nenhum provedor" 16%** (CoinCover/Censuswide, n=2.000, Reino Unido, PDF de 02/07/2026; média-alta).
- [FATO] Conversão no D35: 2,1% freemium, 10,7% hard paywall; retenção de assinantes anuais após 1 ano: 27–28% (RevenueCat SOSA 2026; alta, apps de consumo em geral).
- [ESTIMATIVA] WTP plausível do usuário mediano do Seeker: **US$50–100/ano**. A âncora mental é Cipherwill (US$40), Kresus (US$100) e o próprio Seeker (~US$450–500 uma vez). Acima de US$250, o público já tem Casa e Nunchuk com serviço humano.

---

## 4. Modelo de receita: 3 cenários × 3 anos [ESTIMATIVA]

Modelo mensal de out/2026 a set/2029, partindo dos 10 usuários do alpha.

### 4.1 Premissas

| Premissa                                | Conservador         | Base                   | Otimista                | Base da premissa                                                                              |
| --------------------------------------- | ------------------- | ---------------------- | ----------------------- | --------------------------------------------------------------------------------------------- |
| Cofres ativos no fim dos anos 1 / 2 / 3 | 300 / 1.500 / 4.000 | 1.000 / 6.000 / 20.000 | 3.000 / 20.000 / 60.000 | Ano 1 só Seeker (~72–101 mil ativados [FATO]); Android a partir de meados de 2027             |
| Saldo médio por cofre                   | US$500              | US$1.500               | US$3.000                | Sem dado público; média da Phantom ≈ US$1.667 (US$25B / 15M)                                  |
| Churn mensal de cofres                  | 4%                  | 3%                     | 2%                      | —                                                                                             |
| % do saldo liberado por ano             | 3%                  | 5%                     | 8%                      | Mortalidade ~0,26%/ano aos 35 anos (SSA, média); o resto vem de vesting e silêncios sem morte |
| % do saldo sacado/cancelado por ano     | 25%                 | 30%                    | 30%                     | Cofre usado como reserva                                                                      |
| Saldo dos pagantes (× média)            | 5×                  | 5×                     | 5×                      | Quem assina é quem tem mais saldo                                                             |
| % dos assinantes que pagam em SKR       | 50%                 | 40%                    | 30%                     | —                                                                                             |
| Atual: conversão para US$40/mês         | 0,5%                | 1,5%                   | 3%                      | Abaixo da mediana freemium (2,1%) por causa do break-even de US$96 mil                        |
| Atual: churn mensal de assinantes       | 18%                 | 14%                    | 10%                     | Retenção baixa de planos mensais (RevenueCat)                                                 |
| Recomendado: conversão para US$79/ano   | 2%                  | 5%                     | 8%                      | Perto da mediana freemium, com recursos exclusivos                                            |
| Recomendado: renovação anual            | 30%                 | 45%                    | 60%                     | RevenueCat: 27–28% de retenção anual mediana                                                  |

### 4.2 Resultados (US$, receita bruta)

**Modelo atual** (0,5% na execução e no cancelamento; US$40/mês ou US$35 em SKR com 30% queimado):

| Cenário     | Ano 1  | Ano 2   | Ano 3   | Total 3 anos | Pagantes no fim | Taxa de cancelamento no ano 3 | Queimado no ano 3 |
| ----------- | ------ | ------- | ------- | ------------ | --------------- | ----------------------------- | ----------------- |
| Conservador | 318    | 1.675   | 4.610   | **6.604**    | 9               | 1.763 (38%)                   | 429               |
| Base        | 3.676  | 23.261  | 79.925  | **106.862**  | 151             | 29.294 (37%)                  | 5.685             |
| Otimista    | 24.073 | 169.840 | 537.155 | **731.068**  | 1.006           | 170.461 (32%)                 | 28.625            |

**Modelo recomendado** (0,5% só na liberação; saque grátis; US$79/ano ou US$69 em SKR, sem burn):

| Cenário     | Ano 1  | Ano 2   | Ano 3   | Total 3 anos | Pagantes no fim |
| ----------- | ------ | ------- | ------- | ------------ | --------------- |
| Conservador | 542    | 2.602   | 6.533   | **9.677**    | 86              |
| Base        | 4.487  | 26.159  | 84.323  | **114.970**  | 1.074           |
| Otimista    | 21.314 | 139.682 | 407.273 | **568.268**  | 4.972           |

### 4.3 Leitura

- No conservador e no base, o recomendado empata ou rende mais, com **7 a 10 vezes mais pagantes**.
- No otimista, o atual rende ~29% mais, e quase todo o ganho é a taxa de cancelamento (US$170 mil no ano 3), **que o programa on-chain não cobra hoje**. Sem ela (US$226 mil nos 3 anos), o atual cai para ~US$505 mil, abaixo do recomendado (US$568 mil). O modelo não captura o efeito de remover o pedágio sobre depósitos e adesão.
- A taxa de 0,5% rende ~US$0,38 por usuário típico por ano (cofre de US$1.500, 5% liberado). Mortes geram pouca liberação nos primeiros 3 anos.
- **Em todos os cenários a receita de 3 anos é pequena** (US$10 mil a US$730 mil). O preço não muda a ordem de grandeza; distribuição muda (dApp Store, Android, B2B/SDK para carteiras).
- Custo de patrocinar check-ins é desprezível: 10.000 lamports ≈ US$0,0012 por check-in, ~US$0,06 por usuário por ano com check-in semanal (sem rent nem priority fee).

---

## 5. SKR e burn de 30%

### 5.1 O que é fato

- [FATO] SKR: suprimento de 10B; inflação de staking começando em 10% e caindo até 2%; staking com Guardians que fazem a curadoria da dApp Store (docs Solana Mobile; alta).
- [FATO] Airdrop: 1.819.755.000 SKR para 100.908 usuários (CoinMarketCap Academy, jan/2026); "distributed to almost 72,000 wallets", 40%+ em stake (guia oficial). 75 mil+ resgataram no lançamento (MWC, 02/03/2026).
- [FATO] Precedente oficial: 50% off no Seeker pago em SKR até 21/02/2026 (guia oficial; alta).
- [FATO] **As fontes oficiais não mencionam burn ou buyback de SKR.** Só blogs de exchange falam disso (baixa; não usar).
- [FATO] Precedentes de burn: Inheriti queima 10% da receita em SHA (token próprio, média); BONKbot recompra e queima BONK com parte das taxas (secundária, média); Vault12 dá 50% de desconto em VGT (token próprio, alta).

### 5.2 Impacto [ESTIMATIVA]

- **Receita:** um assinante em SKR rende US$35 × 70% = US$24,50 líquido contra US$40 em USDC, ou **−39%**.
- **Token:** emissão do ano 1 ≈ 1B SKR ≈ US$16M a US$0,0162. O burn do cenário base no ano 3 (US$5,7 mil) é ~0,035% disso. **Efeito no preço: nulo.**
- **Riscos:** volatilidade (−71% da máxima), liquidez baixa (~US$652 mil) para vender o SKR recebido, preço on-chain fixado em unidades de token que precisa de reprecificação (já existe `tool/set_subscription_price.dart` `[INTERNO]`), percepção de "tokenomics de fachada" por investidores.
- **Pontos positivos:** alinhamento com a Solana Mobile, chance de curadoria na dApp Store, uso para o SKR parado do airdrop.

**Veredito:** manter pagamento em SKR com **desconto de 10 a 15%**; **burn de 0 a 10%**, tratado como marketing (o `burn_bps` é configurável por mint sem novo deploy `[INTERNO]`). Fazer stake do SKR recebido num Guardian ou propor co-marketing à Solana Mobile alinha mais que queimar.

---

## 6. Taxa de cancelamento

**Recomendação: eliminar.** Motivos:

1. [INTERNO] **Não existe no programa.** Saque, fechamento de cofre e revogação de vesting são gratuitos on-chain; o slide promete algo que o produto não faz.
2. [FATO] **Ninguém entre os produtos lançados cobra saída** (seção 2).
3. [FATO] **Confiança pesa mais que custo:** segurança 23% e desconfiança de provedor 16%, contra custo 17% (CoinCover).
4. [ESTIMATIVA] **Cria incentivo ruim:** o usuário deposita menos "para testar", e o valor protegido, que é a métrica de tração do deck, encolhe.
5. [ESTIMATIVA] É exatamente o pedágio que um usuário de autocustódia rejeita.

Se for preciso cobrir custo de transação na saída, usar **taxa fixa simbólica** (ex.: 0,001 SOL ≈ US$0,12), nunca porcentagem.

---

## 7. Recomendação final

| Plano                                   | Preço                                             | Inclui                                                                                                                          | Taxa na liberação                                  | Saque  |
| --------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- | ------ |
| **Grátis**                              | US$0                                              | 1 cofre, até 2 tiers, entrega pública, check-in patrocinado (Kora), **Coercion PIN**                                            | **0,5%** (teto opcional por liberação, ex. US$250) | grátis |
| **Plus**                                | **US$79/ano** (ou US$8/mês); **US$69/ano em SKR** | até 8 tiers, entrega privada via Cloak, vesting, janelas personalizadas, Boney customizável, vários cofres, aviso aos herdeiros | **0%** se o dono estava em dia no último check-in  | grátis |
| **Família / Pro** (depois da auditoria) | US$199–249/ano                                    | vários cofres e famílias, suporte humano na hora do herdeiro receber                                                            | 0%                                                 | grátis |

**Justificativa:**

1. **US$79/ano** fica entre Cipherwill (US$40) e Kresus (US$99,99), os comparáveis mais diretos, e dentro da WTP estimada de US$50–100. Break-even contra a taxa: US$15.800/ano (US$13.800 em SKR), por isso o plano vende **recursos**, não só taxa zero.
2. **Cobrança anual primeiro:** em Solana não há débito automático e planos mensais retêm mal. O programa já aceita de 1 a 36 períodos por chamada `[INTERNO]`.
3. **Coercion PIN grátis:** é recurso de segurança física, o diferencial que mais gera conversa e cobrar por ele teria custo ético e de imagem.
4. **0,5% só na liberação** mantém o discurso "só cobramos quando entregamos" e o demo do slide 03 (1 SOL → 0,995). A isenção "morreu em dia, herdeiro recebe 100%" já existe no programa (`paid_until >= last_pulse`) `[INTERNO]` e é bom argumento de venda.
5. **SKR com desconto moderado e burn de 0 a 10%** preserva receita e mantém o alinhamento com o ecossistema.

**Antes de fixar:**

- Testar US$59, US$79 e US$99/ano com os 52 da waitlist e os 10 do alpha (três links de checkout ou Van Westendorp simples).
- Alinhar README, `scripts/devnet_setup.sh` (2%/3%) e config on-chain ao 0,5% do deck, e travar a taxa por plano (hoje o admin pode subir até 5% em planos existentes `[INTERNO]`).
- Verificar a política do Google Play para assinaturas pagas em cripto antes do lançamento Android (não verificado).
- Não usar a palavra "seguro" no material (exigiria licença; não verificado com advogado).
