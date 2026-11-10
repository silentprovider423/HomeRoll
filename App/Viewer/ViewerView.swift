                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Fmt.fullDateTime.string(from: asset.date))
                                .font(.system(size: 16, weight: .semibold))
                            Text(fileName).font(.system(size: 15)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "Anpassen")) { sheet = .dateTime([asset]) }
                    }
