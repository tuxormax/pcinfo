/* drivedb-add.h — base de datos por modelo de PCInfo (estilo CrystalDiskInfo)
 *
 * Formato OFICIAL de smartmontools (mismas 5 columnas que drivedb.h). Se embebe
 * en el binario Go (go:embed) y se pasa a smartctl con `-B +<archivo>`, de modo
 * que smartctl PREPENDE estas entradas a su drivedb.h interno: ganan prioridad y
 * caen al built-in si no matchean. Sirve igual en Linux y Windows (self-contained).
 *
 * Por qué existe: smartctl elige presets por REGEX del modelo. Cuando el regex
 * oficial no cubre una variante concreta (firmware/sufijo), el disco cae al
 * genérico y reporta escrituras/lecturas/vida con la unidad equivocada. Aquí se
 * copian los presets correctos del propio drivedb.h, ampliando el regex.
 *
 * Cómo AGREGAR un modelo (cuando un disco reporte TB/% raros):
 *   1. `smartctl -A /dev/sdX` y compara con la capacidad real.
 *   2. Busca la familia en /var/lib/smartmontools/drivedb/drivedb.h.
 *   3. Copia su bloque "-v ..." y AMPLÍA el regex del modelo (col. 2) para cubrir
 *      la variante. Mantén las unidades embebidas en el nombre (_32MiB, _1GiB):
 *      attrToBytes() en smart.go las interpreta solo.
 *
 * Cada entrada: { "Familia", "REGEX_MODELO", "REGEX_FIRMWARE", "Aviso", "-v presets" }
 */
{
  /* ADATA SU * NS38 (controlador Silicon Motion).
   * El regex oficial de smartmontools cubre "ADATA SU650NS38" y "ADATA SU800"
   * (sin sufijo) pero NO "ADATA SU800NS38" / "SU900NS38": el `SU[89]00` no
   * consume el sufijo "NS38" y el disco cae al genérico Total_LBAs_Written
   * (x512). Toda la familia SU Silicon Motion usa 32 MiB por unidad en 241/242.
   * Verificado real: ADATA SU800NS38 -> 4.18 TiB escritas / 5.37 TiB leídas. */
  "ADATA SU NS38 (Silicon Motion) [PCInfo]",
  "ADATA SU(6[0-9][0-9]|[789]00)NS38",
  "", "",
  "-v 148,raw48,Total_SLC_Erase_Ct "
  "-v 149,raw48,Max_SLC_Erase_Ct "
  "-v 160,raw48,Uncorrectable_Error_Cnt "
  "-v 161,raw48,Valid_Spare_Block_Cnt "
  "-v 163,raw48,Initial_Bad_Block_Count "
  "-v 164,raw48,Total_Erase_Count "
  "-v 165,raw48,Max_Erase_Count "
  "-v 166,raw48,Min_Erase_Count "
  "-v 167,raw48,Average_Erase_Count "
  "-v 168,raw48,Max_Erase_Count_of_Spec "
  "-v 169,raw48,Remaining_Lifetime_Perc "
  "-v 178,raw48,Runtime_Invalid_Blk_Cnt "
  "-v 225,raw48,Host_Writes_32MiB "
  "-v 231,raw48,SSD_Life_Left "
  "-v 241,raw48,Host_Writes_32MiB "
  "-v 242,raw48,Host_Reads_32MiB "
  "-v 245,raw48,TLC_Writes_32MiB "
  "-v 246,raw48,SLC_Writes_32MiB "
  "-v 247,raw48,Raid_Recoverty_Ct "
  "-v 248,raw48,Unkn_SiliconMotion_Attr "
  "-v 249,raw48,Unkn_SiliconMotion_Attr "
  "-v 251,raw48,Unkn_SiliconMotion_Attr"
},
