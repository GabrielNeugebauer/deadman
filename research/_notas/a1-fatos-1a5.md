# A1 — Checagem dos fatos (1) a (5) do deck Deadman

Data de acesso de todas as fontes: 2026-10-07.
Legenda de confiança: **alta** = fonte primária lida diretamente; **média** = fonte secundária confiável ou primária lida só em parte (press release, resumo); **baixa** = agregador sem fonte citada, ou dado inferido.
"FATO VERIFICADO" = lido na fonte. "ESTIMATIVA MINHA" = cálculo ou inferência minha, não da fonte.

Limitação: a cota de buscas web da sessão acabou no meio da checagem das manchetes brasileiras. A matéria original da Exame e a da "noiva" não foram localizadas (ver itens 5a e 5c). Tudo o mais foi lido nas páginas citadas.

Observação: as manchetes do slide 01 foram extraídas das imagens embutidas no deck (`Deadman pitch deck.html`) para conferir veículo, data e subtítulo exibidos.

---

## Resumo

| #   | Afirmação no deck                                                            | Status                                                                                                    | Valor correto / mais recente                                                                                                                                                                  | Confiança                        |
| --- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| 1   | ~60% dos usuários de cripto preferem autocustódia (CoinLaw)                  | **fonte fraca** (o agregador não cita a origem)                                                           | CoinLaw: 59%, sem fonte primária. Melhor fonte primária: 66% consideram a autocustódia importante, mas 88% ainda guardam ativos em corretora (Tangem/Protocol Theory, abr/2026, EUA, n=3.172) | baixa (CoinLaw) / média (Tangem) |
| 2   | 3,7M BTC parados há 5+ anos, provavelmente perdidos (Chainalysis, 2020)      | **confirmado, com ressalvas** (datado; inclui ~1M BTC do Satoshi)                                         | ~3,7M BTC (≈20% da oferta). Faixa de estimativas de outros: 2,3–4,0M                                                                                                                          | média-alta                       |
| 3   | 72 wrench attacks em 2025, +75% sobre 2024 (CertiK)                          | **confirmado**                                                                                            | 72 incidentes verificados em 2025 (≈41 em 2024), US$40,9M em perdas confirmadas                                                                                                               | alta                             |
| 4   | 8.000 BTC perdidos num HD jogado no lixo (Howells)                           | **confirmado como alegação**                                                                              | 8.000 BTC segundo o próprio Howells (reportagens de 2013 a 2021 falavam em 7.500). Ação extinta em jan/2025 e recurso negado em mar/2025                                                      | alta (sentença)                  |
| 5a  | "1 em cada 3 investidores já perdeu acesso à carteira" (Exame/Oobit)         | **confirmado na fonte primária (Oobit)**, mas a matéria da Exame não foi localizada; o subtítulo distorce | 35% de 1.000 detentores **nos EUA**. 31% dos afetados nunca recuperaram os ativos                                                                                                             | alta (Oobit)                     |
| 5b  | "Investidor perde R$1 milhão após ter o celular roubado em SP"               | **confirmado, com ressalva de valor e contexto**                                                          | R$ 920 mil (manchete arredondou). Fundos na Binance e numa Trezor; ~R$ 626 mil rastreados                                                                                                     | alta                             |
| 5c  | "Homem perde R$1 milhão após noiva esvaziar carteira com a seed"             | **sem fonte** (não encontrado)                                                                            | —                                                                                                                                                                                             | —                                |
| 5d  | "US$190 milhões congelados após a morte do único dono da senha" (QuadrigaCX) | **desatualizado/enganoso**                                                                                | US$190M ≈ C$250M devidos no total (fiat + cripto). A investigação da OSC (2020) concluiu que houve **fraude**: perdas ≥ C$169M, e a maior parte não se deve à senha perdida                   | alta                             |

---

## (1) "~60% dos usuários de cripto preferem autocustódia" — CoinLaw

**Status: fonte fraca.** O número existe na CoinLaw, mas o agregador não indica de onde ele vem.

FATO VERIFICADO:

- A CoinLaw ("Self-Custody Wallet Statistics", publicada em nov/2025 e atualizada em 16/08/2026) diz: "59% of crypto wallet users globally in 2025 prefer non-custodial (self-custody) wallets versus custodial solutions." A mesma página traz "56.58% of users now prefer self-custody wallets, while 26.97% trust exchanges" e "For hot wallets in 2025, custodial models account for ~41%, non-custodial ~59%". **Nenhum desses números traz fonte primária individual.** A página só lista referências genéricas no fim (LiquidityFinder, AInvest, Biometric Update, CNBC).
- A frase "~59% non-custodial" aparece num contexto de _hot wallets_, que parece segmentação de mercado e não preferência declarada de usuários (inferência minha, confiança baixa).
- O 56,58%/26,97% aparece também em blog da Safeheron, empresa de custódia, sem metodologia.
- **Melhor fonte primária disponível:** Tangem + Protocol Theory, relatório "From Storage to Participation: The Rise of Active Self-Custody", press release de 23–24/04/2026 (Business Wire), com 3.172 usuários de cripto **dos EUA**. Resultados: "66% of users consider self-custody important", "88% still store assets on centralized exchanges", "only 33% use a cold wallet", "46% fear major exchange breaches". O próprio Tangem/Protocol Theory foi citado por outro veículo com "only 15% actually use hardware wallets". Isso conflita com os 33% de cold wallet; o press release diz 33%.

CONFLITO: CoinLaw (59%, sem fonte) vs. Tangem/Protocol Theory (66% acham importante, 88% ainda usam corretora).
**Qual usar:** Tangem/Protocol Theory, que tem amostra, país e autoria declarados. Mas ela mede "considera importante", não "prefere". Atenção: a Tangem vende carteiras de hardware (conflito de interesse). Cite como pesquisa encomendada.

**Texto sugerido para o slide:**

> "2 em cada 3 usuários de cripto dizem que a autocustódia é importante." — Tangem/Protocol Theory, 2026 (EUA, n=3.172)

Alternativa que reforça a tese ("todos querem autocustódia, poucos têm plano"): "66% valorizam a autocustódia; 88% ainda deixam ativos em corretoras."

---

## (2) "3,7M BTC parados há 5+ anos, provavelmente perdidos" — Chainalysis, 2020

**Status: confirmado, com ressalvas.** O número é da Chainalysis, mas é antigo e a definição de "perdido" é ampla.

FATO VERIFICADO:

- O blog da Chainalysis "Why Bitcoin is Surging and How This Rally Is Different from 2017" (19/11/2020) diz, lido na fonte: "...77% of the 14.8 million Bitcoin mined that isn't categorized as lost, meaning it hasn't moved from its current address in five years or longer." A definição de "lost" da Chainalysis é, portanto, **sem movimento há 5 anos ou mais**.
- Relatório Chainalysis de jun/2020 ("60% of Bitcoin is Held Long Term as Digital Gold. What About the Rest?"): ~20% dos BTC em circulação não se moveram em 5+ anos e são tratados como perdidos. Cerca de 3,7M BTC, **incluindo ~1,1M BTC atribuídos ao Satoshi**. Confiança média: o link original redireciona para o índice do blog e só li coberturas secundárias (CryptoPotato e Cointelegraph via resultados de busca; BTC-Echo de 21/11/2020 confirma "3,7 Millionen Bitcoin").
- O estudo anterior da Chainalysis, de 2017 (Fortune, 25/11/2017), estimava de 2,78M a 3,79M BTC perdidos: "Both estimates make a critical assumption that coins belonging to bitcoin's inventor, Satoshi, are gone for good."

ESTIMATIVA MINHA: em nov/2020 havia ~18,5M BTC minerados. 18,5M − 14,8M ≈ 3,7M, o que bate com o número do deck.

Outras estimativas (via blog da BitGo, secundário, confiança baixa): River 3,0–4,0M (set/2023), Ledger 2,3–3,7M (nov/2025), Unchained 3,0–3,8M (abr/2026). Não encontrei nenhuma atualização da própria Chainalysis depois de 2020.

Ressalva para o pitch: "parado há 5+ anos" ≠ "perdido com certeza". Parte disso é HODL deliberado, e ~1M é do Satoshi. Isso não é "herança perdida". A palavra "provavelmente" no deck é adequada.

**Texto sugerido para o slide:**

> "~3,7 milhões de BTC (≈1 em cada 5) não se movem há mais de 5 anos e são dados como perdidos." — Chainalysis, 2020

---

## (3) "72 wrench attacks em 2025, alta de 75% sobre 2024" — CertiK

**Status: confirmado.**

FATO VERIFICADO (CertiK, "Skynet Wrench Attacks Report", 02/02/2026, lido na fonte):

- "72 verified physical coercion incidents worldwide, a 75% increase compared to 2024."
- Perdas confirmadas: "$40.9 million, up 44% from 2024", que "significantly understate the true impact due to under-reporting, silent settlements, and untraceable ransoms."
- Europa: "over 40% of global incidents". A França teve o maior número de ataques (19 segundo a Cointelegraph), acima dos EUA. Agressões físicas subiram 250% no ano. O sequestro segue como o principal vetor (25 casos em 2025 contra 15 em 2024, segundo a cobertura da Cointelegraph/Yahoo).
- O número de 2024 (41) aparece na Cointelegraph ("approximately 41"). A página da CertiK não dá o número exato. ESTIMATIVA MINHA: 72/1,75 ≈ 41, o que é consistente.
- **Achado útil para o deck:** entre as defesas, a CertiK propõe "panic wallet" que "display decoy funds during attacks" (citado pela Cointelegraph). É exatamente a proposta do Coercion PIN.
- Complemento: a lista pública de Jameson Lopp (github.com/jlopp/physical-bitcoin-attacks) traz casos no Brasil em 2025 (São Paulo, Campo Limpo Paulista, Recife/Imbiribeira). Não conferi as contagens por ano (confiança baixa).

**Texto sugerido para o slide:**

> "72 ataques físicos para roubar cripto em 2025: +75% em um ano." — CertiK, fev/2026

Opcional: "A própria CertiK recomenda carteiras de pânico com saldo falso."

---

## (4) "8.000 BTC perdidos num HD jogado no lixo" — James Howells, aterro de Newport

**Status: confirmado como alegação de Howells.** A quantidade nunca foi comprovada de forma independente.

FATO VERIFICADO:

- Sentença _James Howells v Newport City Council_ [2025] EWHC 22 (Ch), de 09/01/2025 (National Archives, lida na fonte). Howells afirma ter minerado "8,000 Bitcoin in early 2009" (§15). O HD teria sido depositado no aterro Docksway em "5th August 2013" (§15). Ele diz que os BTC valem "in excess of £600 million" (§1). Decisão: "There will be judgment for the defendant and the claim will be dismissed" (§55). Fundamento: pelo Control of Pollution Act 1974, s.14(6)(c), o que é entregue ao aterro passa a pertencer à autoridade local.
- No Tribunal de Recurso, Lord Justice Nugee negou a permissão para recorrer em 13/03/2025 (Cointelegraph/Decrypt; confiança média).
- Em fev/2025, o conselho de Newport anunciou o fechamento do aterro no ano fiscal 2025–26 (BBC, via secundárias; confiança média). Em ago/2025, Howells disse à Forbes Australia que desistiu de escavar e partiu para tokenizar os "direitos" sobre os BTC (Ceiniog Coin). Ele nega ter "desistido" dos BTC (The Block).
- Divergência de quantidade: as reportagens de 2013 a 2021 falavam em **7.500 BTC**, e a partir de 2022 em **8.000 BTC** (Wikipedia, seção Notes; confiança média). Na sentença consta 8.000.
- Contexto: foi a então companheira dele quem levou o lixo ao aterro, segundo o relato de Howells; ela nega culpa.

**Texto sugerido para o slide:**

> "8.000 BTC num HD jogado no lixo em 2013. Em 2025, a Justiça britânica encerrou o caso: o aterro venceu."

Se for usar valor em dólar, informe a cotação e a data. Não usei preço atual.

---

## (5) Manchetes

### 5a. "1 em cada 3 investidores já perdeu acesso à carteira" — Exame / Oobit

**Status: o dado está confirmado na fonte primária (Oobit), mas a matéria da Exame não foi localizada e o subtítulo usado no deck distorce o dado.**

O que o deck mostra (imagem): seção "Future of Money" da Exame, título "Research indicates that 1 in 3 cryptocurrency investors have already lost access to their wallet", subtítulo "A survey sent exclusively to EXAME by Oobit also revealed that almost a third of them never recovered their money after forgetting their passwords."

FATO VERIFICADO (Oobit, "Lost or Locked Out: How Many People Have Actually Lost Access to Their Crypto?", oobit.com/lost-or-locked-out, lido na fonte):

- Amostra de 1.000 detentores de cripto **dos EUA**, via CloudResearch Connect.
- "Over 1 in 3 of crypto holders (35%) have lost access to a wallet or account." Atenção: "wallet **ou conta**", o que inclui contas em corretoras.
- "nearly 1 in 3 (31%) have never recovered their assets", entre os que perderam acesso, por **qualquer causa**.
- Causas: senha esquecida 33%, seed perdida 21%, 2FA 20%, falência de plataforma 16% (news.bitcoin.com/pt, 04/04/2026).
- "12% lost over $5,000 in crypto value from a single incident."

Distorções:

1. O subtítulo atribui o "nunca recuperaram" a esquecer a senha. Na pesquisa, os 31% valem para todas as causas.
2. A amostra é dos EUA, não do Brasil.
3. "Investidores" na manchete vs. "holders" com "wallet or account" na pesquisa.
4. A Oobit é uma empresa de pagamentos com cripto, ou seja, tem interesse comercial.

Matéria original da Exame: **não encontrada.** A busca no site e a tentativa de URL deram 404, e a cota de buscas acabou. Antes de citar "Exame", o dono do projeto precisa colar o link.

**Texto sugerido para o slide:**

> "1 em cada 3 detentores de cripto já perdeu acesso a uma carteira ou conta." — Oobit, 2026 (EUA, n=1.000)

### 5b. "Investidor perde R$1 milhão após ter o celular roubado em São Paulo"

**Status: confirmado, com ressalva de valor e contexto.**

FATO VERIFICADO (Livecoins, "Investidor perde R$ 1 milhão em criptomoedas após ter celular roubado em SP", por Vinicius Golveia, 16/02/2024; é exatamente a imagem do deck):

- O valor no corpo da matéria é **R$ 920 mil** em BTC, USDT e ETH. A manchete arredonda para R$ 1 milhão.
- Contexto: a vítima foi assaltada e teve o celular levado. "sua conta na Binance foi drenada e, apesar de conseguir transferir parte dos fundos para uma carteira Trezor, os ladrões também acessaram o dispositivo e roubaram os ativos." A matéria não explica como os ladrões obtiveram acesso à Trezor.
- Recuperação: a Blockseers rastreou 2,93 BTC (~R$ 626 mil). O TJSP (processo 2351130-19.2023.8.26.0000, des. Rômolo Russo) mandou bloquear os fundos.
- Não confundir com outro caso, também da Livecoins (09/05/2023): a Binance foi condenada a restituir **R$ 310 mil** a outra vítima de celular roubado em SP.

Distorção: pequena no valor (R$ 920 mil vs. R$ 1 mi). No contexto, foi principalmente uma conta **custodial** (Binance) invadida após o roubo, o que é um argumento mais fraco para um cofre de autocustódia. Serve para ilustrar o risco do celular como ponto único de falha.

**Texto sugerido:** manter a manchete e acrescentar a fonte "Livecoins, fev/2024". Se citar o valor no texto, usar "~R$ 920 mil".

### 5c. "Homem perde R$1 milhão após a noiva esvaziar a carteira com a seed phrase"

**Status: sem fonte (não encontrado).**

- A imagem no deck mostra "Man loses R$1 million in cryptocurrencies after fiancée empties his wallet using a security phrase entrusted to her for emergencies", com "BY EDITORIAL STAFF | OCTOBER 6, 2026", sem nome do veículo.
- Três buscas em português e inglês não acharam a matéria. Achei só casos parecidos: Ping Fai Yuen vs. Fun Yung Li (Reino Unido, 2.323 BTC, câmeras escondidas, ago/2023, processo na High Court) e um caso de "ex-noiva" no Tocantins (out/2026), que **não** envolve cripto.
- A matéria seria de 06/10/2026, véspera desta checagem, e pode não estar indexada ainda.

**Recomendação:** não usar no deck até ter veículo, link e data. Se for mantida, trocar pelo caso Yuen/Li, que é documentado em juízo. Ele ilustra o mesmo risco: confiar a seed a uma pessoa próxima. O Deadman resolve isso sem entregar a seed a ninguém.

### 5d. "US$190 milhões congelados após a morte do único dono da senha" — QuadrigaCX

**Status: desatualizado/enganoso.** O valor de 2019 mistura moedas, e a investigação posterior mostrou que a "senha perdida" não explica as perdas.

FATO VERIFICADO:

- **Valor e moeda.** Na declaração juramentada de Jennifer Robertson (viúva de Gerald Cotten), em 31/01/2019, a Quadriga devia ~**C$250M** a ~115 mil usuários: C$70M em fiat e C$180M em cripto. A CoinDesk (01/02/2019) converteu: "roughly $250 million CAD ($190 million)". **Os US$190M são o total devido, fiat incluído**, e não só cripto congelada. Outros veículos noticiaram "C$190M (≈US$145M)" em cripto inacessível, e a Reuters noticiou C$180M ≈ US$137M em cripto (secundários; confiança média). A manchete do deck ("$190 million in cryptocurrency frozen") mistura as duas coisas.
- **O que aconteceu.** Cotten morreu na Índia em 09/12/2018. A empresa pediu proteção contra credores na Nova Escócia em jan/2019. A EY, como monitora, encontrou as cold wallets **vazias desde abr/2018**, segundo o Terceiro Relatório do Monitor, de 01/03/2019 (via Cointelegraph/secundárias; confiança média).
- **Investigação posterior.** O relatório da Ontario Securities Commission, "QuadrigaCX: A Review by Staff of the OSC" (11/06/2020, lido na fonte), concluiu:
  - "Over 76,000 clients were owed a combined $215 million" (C$), e "collectively lost at least $169 million" (C$).
  - "The bulk of the asset shortfall—approximately $115 million—arose from Cotten's fraudulent trading on the Quadriga platform", mais C$28M perdidos por Cotten operando em outras corretoras.
  - "It has been widely speculated that the bulk of investor losses resulted from crypto assets becoming lost or inaccessible as a result of Cotten's death. In our assessment, this was not the case."
  - A EY recuperou ou identificou só C$46M. A OSC descreveu o esquema como "an effective Ponzi scheme" (The Block, 11/06/2020).
- Em dez/2019, advogados dos clientes pediram à RCMP a exumação do corpo de Cotten. **Não encontrei** confirmação pública do desfecho, nem de acusações criminais pela RCMP.

CONFLITO: US$190M (CoinDesk, total devido) vs. C$190M/≈US$145M (outros, cripto) vs. C$169M (OSC, perda final apurada).
**Qual usar:** a OSC (2020), que é a fonte oficial e a mais recente.

Uso no pitch: o caso é sobre **custódia centralizada e falta de controles**, não sobre herança de autocustódia. Usá-lo como "senha morreu junto" repete uma narrativa que o regulador desmentiu. Duas saídas honestas:

- Reenquadrar como "confiar em uma única pessoa ou empresa é o risco", argumento pró-autocustódia com regras on-chain verificáveis.
- Trocar por um caso de autocustódia (por exemplo Howells, item 4).

**Texto sugerido para o slide:**

> "QuadrigaCX (2019): o fundador morre como único dono das chaves; 76 mil clientes perdem C$169 mi. Depois, o regulador descobriu fraude." — OSC, 2020

---

## Tabela de fontes

| #   | Título                                                                                                                                        | URL                                                                                                                                                                   | Data da fonte                       | Acesso     | Confiança                        |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------- | ---------- | -------------------------------- |
| 1   | CoinLaw — Self-Custody Wallet Statistics                                                                                                      | https://coinlaw.io/self-custody-wallet-statistics/                                                                                                                    | nov/2025 (atualizada em 16/08/2026) | 2026-10-07 | baixa                            |
| 1   | Global Fintech Series — "New Research: Crypto Users are Increasingly Relying on Self-Custody Solutions…" (press release Tangem/Business Wire) | https://globalfintechseries.com/cryptocurrency/new-research-crypto-users-are-increasingly-relying-on-self-custody-solutions-to-send-receive-and-grow-assets/          | 24/04/2026                          | 2026-10-07 | média                            |
| 1   | Business Wire — mesmo press release (403 no acesso)                                                                                           | https://www.businesswire.com/news/home/20260423585597/en/New-Research-Crypto-Users-are-Increasingly-Relying-on-Self-Custody-Solutions-to-Send-Receive-and-Grow-Assets | 23/04/2026                          | 2026-10-07 | média (não lido)                 |
| 1   | KuCoin News — "Survey: 66% of crypto users value self-custody"                                                                                | https://www.kucoin.com/news/flash/survey-66-of-crypto-users-value-self-custody                                                                                        | 2026 (sem data na página)           | 2026-10-07 | baixa                            |
| 2   | Chainalysis — "Why Bitcoin is Surging and How This Rally Is Different from 2017"                                                              | https://www.chainalysis.com/blog/bitcoin-price-surge-explained-2020/                                                                                                  | 19/11/2020                          | 2026-10-07 | alta                             |
| 2   | Chainalysis — "60% of Bitcoin is Held Long Term as Digital Gold…" (redireciona para o índice)                                                 | https://blog.chainalysis.com/reports/bitcoin-market-data-exchanges-trading/                                                                                           | jun/2020                            | 2026-10-07 | média (conteúdo via secundárias) |
| 2   | BTC-Echo — "Chainalysis: Bereits 3.700.000 BTC für immer verloren"                                                                            | https://www.btc-echo.de/news/chainalysis-bereits-3-700-000-btc-fuer-immer-verloren-104854/                                                                            | 21/11/2020                          | 2026-10-07 | média                            |
| 2   | Fortune — "Nearly 4 Million Bitcoins Lost Forever" (Roberts & Rapp)                                                                           | https://fortune.com/2017/11/25/lost-bitcoins/                                                                                                                         | 25/11/2017                          | 2026-10-07 | média                            |
| 2   | BitGo — "Bitcoin's invisible burn: lost coins outpace new supply"                                                                             | https://bitgo.com/resources/blog/bitcoins-invisible-burn-lost-coins-outpace-new-supply/                                                                               | 2026 (sem data)                     | 2026-10-07 | baixa                            |
| 3   | CertiK — Skynet Wrench Attacks Report                                                                                                         | https://www.certik.com/blog/skynet-wrench-attacks-report                                                                                                              | 02/02/2026                          | 2026-10-07 | alta                             |
| 3   | Cointelegraph — "Wrench attacks… CertiK"                                                                                                      | https://cointelegraph.com/news/wrench-attacks-increased-losses-certik                                                                                                 | fev/2026                            | 2026-10-07 | média                            |
| 3   | Jameson Lopp — Physical Bitcoin Attacks (lista)                                                                                               | https://github.com/jlopp/physical-bitcoin-attacks                                                                                                                     | contínua                            | 2026-10-07 | baixa (contagem não verificada)  |
| 4   | James Howells v Newport City Council [2025] EWHC 22 (Ch)                                                                                      | https://caselaw.nationalarchives.gov.uk/ewhc/ch/2025/22                                                                                                               | 09/01/2025                          | 2026-10-07 | alta                             |
| 4   | Decrypt — "Wales Man Loses Appeal to Dig Out Hard Drive…"                                                                                     | https://decrypt.co/310043/wales-man-loses-appeal-to-dig-out-hard-drive-holding-676-million-in-bitcoin                                                                 | mar/2025                            | 2026-10-07 | média (via busca)                |
| 4   | Forbes Australia — "James lost $1.4 billion in Bitcoin to a landfill…"                                                                        | https://www.forbes.com.au/covers/investing/buried-bitcoin-inside-james-howells-1-4-billion-landfill-disaster/                                                         | ago/2025                            | 2026-10-07 | média (via busca)                |
| 4   | Wikipedia — Bitcoin buried in Newport landfill                                                                                                | https://en.wikipedia.org/wiki/Bitcoin_buried_in_Newport_landfill                                                                                                      | atualizada 2026                     | 2026-10-07 | média                            |
| 5a  | Oobit — "Lost or Locked Out: How Many People Have Actually Lost Access to Their Crypto?"                                                      | https://www.oobit.com/lost-or-locked-out                                                                                                                              | 2026 (≈abr/2026)                    | 2026-10-07 | alta                             |
| 5a  | Bitcoin.com News (PT) — "Erros humanos, e não ataques cibernéticos…"                                                                          | https://news.bitcoin.com/pt/erros-humanos-e-nao-ataques-ciberneticos-sao-apontados-como-a-principal-causa-da-perda-de-acesso-a-criptomoedas/                          | 04/04/2026                          | 2026-10-07 | média                            |
| 5a  | Exame (matéria original)                                                                                                                      | **não encontrado**                                                                                                                                                    | —                                   | 2026-10-07 | —                                |
| 5b  | Livecoins — "Investidor perde R$ 1 milhão em criptomoedas após ter celular roubado em SP"                                                     | https://livecoins.com.br/investidor-perde-r-1-milhao-em-criptomoedas-celular-roubado/                                                                                 | 16/02/2024                          | 2026-10-07 | alta                             |
| 5b  | Livecoins — "Binance é condenada a restituir investidor que teve celular roubado em São Paulo" (outro caso)                                   | https://livecoins.com.br/binance-e-condenada-a-restituir-investidor-celular-roubado-em-sao-paulo/                                                                     | 09/05/2023                          | 2026-10-07 | alta                             |
| 5c  | Matéria da "noiva"                                                                                                                            | **não encontrado**                                                                                                                                                    | (imagem do deck: 06/10/2026)        | 2026-10-07 | —                                |
| 5d  | OSC — QuadrigaCX: A Review by Staff of the Ontario Securities Commission                                                                      | https://osc.ca/quadrigacxreport/index.html                                                                                                                            | 11/06/2020                          | 2026-10-07 | alta                             |
| 5d  | The Block — "Ontario securities regulator publishes investigative report on QuadrigaCX"                                                       | https://www.theblock.co/post/68022/osc-investigation-report-quadrigacx                                                                                                | 11/06/2020                          | 2026-10-07 | média                            |
| 5d  | CoinDesk — "QuadrigaCX Owes Customers $190 Million, Court Filing Shows"                                                                       | https://www.coindesk.com/markets/2019/02/01/quadrigacx-owes-customers-190-million-court-filing-shows                                                                  | 01/02/2019                          | 2026-10-07 | alta                             |
| 5d  | Fortune — QuadrigaCX / Gerald Cotten frozen funds                                                                                             | https://fortune.com/2019/02/04/cryptocurrency-quadrigacx-gerald-cotten-frozen-funds/                                                                                  | 04/02/2019                          | 2026-10-07 | média                            |
| 5d  | Cointelegraph — "QuadrigaCX Users Lose $190M as Speculations Over Cotten's Death Swirl"                                                       | https://cointelegraph.com/features/quadrigacx-users-lose-190m-as-speculations-over-cottens-death-swirl                                                                | 27/06/2019                          | 2026-10-07 | média                            |
