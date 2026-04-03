defmodule Rho.Demos.Bazi.ChartCalculator do
  @moduledoc """
  Deterministic BaZi chart calculator using lunar-python.
  Called directly by the coordinator GenServer, not by LLM agents.
  Returns structured chart data in the same format as Chairman's image parsing.
  """

  @doc """
  Calculate BaZi chart from birth date and time.

  Args:
    - year: integer (e.g., 1995)
    - month: integer (1-12)
    - day: integer (1-31)
    - hour: integer (0-23, Chinese 时辰 will be derived)
    - minute: integer (0-59, optional, default 0)
    - gender: :male or :female (needed for 大运 direction)

  Returns:
    {:ok, %{
      "day_master" => "乙木",
      "pillars" => %{
        "year" => %{"stem" => "丙", "branch" => "子", "hidden_stems" => ["癸"], "ten_god" => "伤官"},
        ...
      },
      "da_yun" => [...],  # 大运 10-year luck pillars
      "liu_nian" => %{...},  # current 流年
      "wu_xing_power" => %{...},  # five element strengths
      "notes" => "..."
    }}
    | {:error, String.t()}
  """
  def calculate(year, month, day, hour, minute \\ 0, gender \\ :male) do
    gender_int = if gender == :male, do: 1, else: 0

    python_code = """
from lunar_python import Lunar, Solar, EightChar

# Convert solar to lunar date
solar = Solar.fromYmdHms(#{year}, #{month}, #{day}, #{hour}, #{minute}, 0)
lunar = solar.getLunar()
eight_char = lunar.getEightChar()

# Day Master
day_gan = eight_char.getDayGan()
day_zhi = eight_char.getDayZhi()

# Five elements mapping
gan_wuxing = {
    '甲': '木', '乙': '木', '丙': '火', '丁': '火', '戊': '土',
    '己': '土', '庚': '金', '辛': '金', '壬': '水', '癸': '水'
}

# Yin/Yang
gan_yinyang = {
    '甲': '阳', '乙': '阴', '丙': '阳', '丁': '阴', '戊': '阳',
    '己': '阴', '庚': '阳', '辛': '阴', '壬': '阳', '癸': '阴'
}

day_master_element = gan_wuxing.get(day_gan, '')
day_master = f"{day_gan}{day_master_element}"

# Ten Gods calculation
def get_ten_god(day_gan, other_gan):
    if not other_gan or not day_gan:
        return ''
    day_wx = gan_wuxing.get(day_gan, '')
    other_wx = gan_wuxing.get(other_gan, '')
    day_yy = gan_yinyang.get(day_gan, '')
    other_yy = gan_yinyang.get(other_gan, '')
    same_yy = (day_yy == other_yy)

    wuxing_order = ['木', '火', '土', '金', '水']
    di = wuxing_order.index(day_wx) if day_wx in wuxing_order else -1
    oi = wuxing_order.index(other_wx) if other_wx in wuxing_order else -1

    if di < 0 or oi < 0:
        return ''

    # Same element
    if day_wx == other_wx:
        return '比肩' if same_yy else '劫财'
    # I produce (我生)
    if wuxing_order[(di + 1) % 5] == other_wx:
        return '食神' if same_yy else '伤官'
    # Produces me (生我)
    if wuxing_order[(di - 1) % 5] == other_wx:
        return '偏印' if same_yy else '正印'
    # I overcome (我克)
    if wuxing_order[(di + 2) % 5] == other_wx:
        return '偏财' if same_yy else '正财'
    # Overcomes me (克我)
    if wuxing_order[(di - 2) % 5] == other_wx:
        return '偏官' if same_yy else '正官'
    return ''

# Hidden stems for each branch
zhi_cang_gan = {
    '子': ['癸'], '丑': ['己', '癸', '辛'], '寅': ['甲', '丙', '戊'],
    '卯': ['乙'], '辰': ['戊', '乙', '癸'], '巳': ['丙', '庚', '戊'],
    '午': ['丁', '己'], '未': ['己', '丁', '乙'], '申': ['庚', '壬', '戊'],
    '酉': ['辛'], '戌': ['戊', '辛', '丁'], '亥': ['壬', '甲']
}

def build_pillar(gan, zhi, day_gan_ref):
    hidden = zhi_cang_gan.get(zhi, [])
    ten_god = get_ten_god(day_gan_ref, gan)
    return {
        'stem': gan,
        'branch': zhi,
        'hidden_stems': hidden,
        'ten_god': ten_god
    }

pillars = {
    'year': build_pillar(eight_char.getYearGan(), eight_char.getYearZhi(), day_gan),
    'month': build_pillar(eight_char.getMonthGan(), eight_char.getMonthZhi(), day_gan),
    'day': build_pillar(day_gan, day_zhi, day_gan),
    'hour': build_pillar(eight_char.getTimeGan(), eight_char.getTimeZhi(), day_gan)
}
pillars['day']['ten_god'] = '日元'

# 大运 (Da Yun) - 10-year luck pillars
try:
    yun = eight_char.getYun(#{gender_int})
    da_yun_list = []
    for dy in yun.getDaYun():
        start_age = dy.getStartAge()
        gan = dy.getGanZhi()
        if start_age >= 0 and gan:
            da_yun_list.append({
                'start_age': start_age,
                'gan_zhi': gan,
            })
except Exception:
    da_yun_list = []

# 流年 (Liu Nian) - current year
import datetime
current_year = datetime.datetime.now().year
try:
    current_solar = Solar.fromYmd(current_year, 6, 1)
    current_lunar = current_solar.getLunar()
    current_ec = current_lunar.getEightChar()
    liu_nian = {
        'year': current_year,
        'gan_zhi': current_ec.getYearGan() + current_ec.getYearZhi()
    }
except Exception:
    liu_nian = {'year': current_year, 'gan_zhi': ''}

result = {
    'day_master': day_master,
    'pillars': pillars,
    'da_yun': da_yun_list,
    'liu_nian': liu_nian,
    'notes': f'Solar: {solar.toYmd()}, Lunar: {lunar.toYmd()}'
}

import json
json.dumps(result, ensure_ascii=False)
"""

    try do
      {result, _globals} = Pythonx.eval(python_code, %{})
      json_str = Pythonx.decode(result)

      case Jason.decode(json_str) do
        {:ok, chart_data} -> {:ok, chart_data}
        {:error, _} -> {:error, "Failed to parse Python output as JSON"}
      end
    rescue
      e -> {:error, "Python calculation error: #{Exception.message(e)}"}
    end
  end

  @doc """
  Compare two chart data maps and return a list of differences.
  Used for cross-validation between image parsing and calculation.

  Returns list of difference strings, empty if charts match.
  """
  def compare_charts(chart_a, chart_b) do
    pillar_names = [{"year", "年柱"}, {"month", "月柱"}, {"day", "日柱"}, {"hour", "时柱"}]

    Enum.flat_map(pillar_names, fn {key, label} ->
      pa = get_in(chart_a, ["pillars", key]) || %{}
      pb = get_in(chart_b, ["pillars", key]) || %{}

      diffs = []

      stem_a = pa["stem"]
      stem_b = pb["stem"]
      diffs = if stem_a && stem_b && stem_a != stem_b do
        ["#{label}天干: 图片为 #{stem_a}，计算为 #{stem_b}" | diffs]
      else
        diffs
      end

      branch_a = pa["branch"]
      branch_b = pb["branch"]
      diffs = if branch_a && branch_b && branch_a != branch_b do
        ["#{label}地支: 图片为 #{branch_a}，计算为 #{branch_b}" | diffs]
      else
        diffs
      end

      diffs
    end)
  end
end
