#!/bin/bash

# Текущая дата и время в секундах с начала эпохи
current_time_sec=$(date +%s)

# Указываем URL для отправки данных
url="localhost:8428/api/v1/import/prometheus"

# Создаем папку done, если она не существует
mkdir -p done

# Формируем маску для поиска файлов
mask="2[4-6][0-1][0-9][0-2][0-9][0-5][0-9]*.txt"

# Находим файлы по маске
files=$(ls $mask 2>/dev/null)

# Проверяем, найдены ли файлы
if [ -z "$files" ]; then
    echo "Файлы не найдены!"
    exit 1
fi

# Создаем папки, если они не существуют
mkdir -p old unknown

# Перебираем найденные файлы и проверяем их срок годности
for file in $files; do
    # Извлекаем дату и время из имени файла
    file_date="${file:0:6}"  # ГГММДД
    file_time="${file:6:4}"  # ЧЧММ

    # Преобразуем дату в формат YYYY-MM-DD
    year="20${file_date:0:2}"
    month="${file_date:2:2}"
    day="${file_date:4:2}"
    hour="${file_time:0:2}"
    minute="${file_time:2:2}"

    # Проверяем валидность времени (часы < 24 и минуты < 60)
    if (( 10#$hour >= 24 || 10#$minute >= 60 )); then
        echo "Неверное время для файла $file. Перемещаем в папку unknown."
        mv "$file" unknown/
        continue
    fi

    # Преобразуем дату и время в секунды с начала эпохи
    file_time_sec=$(date -d "${year}-${month}-${day} ${hour}:${minute}" +%s 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        echo "Ошибка преобразования даты для файла $file. Перемещаем в папку unknown."
        mv "$file" unknown/
        continue
    fi

    # Сравниваем разницу времени, чтобы знать, не старше ли файл 5 минут
    if (( current_time_sec - file_time_sec > 300 )); then
        mv "$file" old/
        echo "Файл $file перемещен в папку old: файл старше 5 минут."
        continue
    fi

    # Флаг для отслеживания успешной обработки файла
    all_success=true

    # Обработка файлов с "NV" в имени
    if [[ "$file" == *NV* ]]; then
        # Считываем первую строку для получения значений лейблов (пропускаем первый столбец)
        IFS=$'\t' read -r _ label2 label3 label4 label5 label6 < "$file"

        while IFS=$'\t' read -r col1 col2 col3 col4 col5; do
            # Формируем данные для отправки метрики NV
            data_value="NV{$label2=\"$col2\", $label3=\"$col3\", $label4=\"$col4\"} $col5"

            # Отправляем метрику
            response_value=$(curl -s -w "%{http_code}" -o /dev/null -X POST -d "$data_value" "$url")

            # Проверяем статус отправки для метрики
            if [[ $response_value -ne 200 && $response_value -ne 204 ]]; then
                echo "Ошибка при отправке данных из файла $file (metric: NV). Код ответа: $response_value"
                all_success=false
            else
                echo "Данные из файла $file (metric: NV) успешно отправлены: $data_value"
            fi
        done < <(tail -n +2 "$file")  # Пропускаем первую строку

    # Обработка файлов с "LV" в имени
    elif [[ "$file" == *LV* ]]; then
        # Считываем первую строку для получения значений лейблов (пропускаем первый столбец)
        IFS=$'\t' read -r _ label2 label3 label4 label5 label6 label7 < "$file"

        while IFS=$'\t' read -r col1 col2 col3 col4 col5 col6 col7; do
            # Заменяем пробелы и скобки на подчеркивание в первом столбце
            formatted_col1=$(echo "$col1" | tr -s ' ' '_' | tr -s '(' '_' | tr -s ')' '_' | sed 's/[ _]$//')

            # Формируем данные для отправки метрик
            data_value1="LV{label2=\"$label2\"} $col2"
            data_value2="LV{label2=\"$label3\"} $col3"

            # Отправляем первые метрики
            response_value1=$(curl -s -w "%{http_code}" -o /dev/null -X POST -d "$data_value1" "$url")
            response_value2=$(curl -s -w "%{http_code}" -o /dev/null -X POST -d "$data_value2" "$url")

            # Проверяем статус отправки для первой метрики
            if [[ $response_value1 -ne 200 && $response_value1 -ne 204 ]]; then
                echo "Ошибка при отправке данных из файла $file (metric: LV). Код ответа: $response_value1"
                all_success=false
            else
                echo "Данные из файла $file (metric: LV, label: $formatted_col1) успешно отправлены."
            fi

            # Проверяем статус отправки для второй метрики
            if [[ $response_value2 -ne 200 && $response_value2 -ne 204 ]]; then
                echo "Ошибка при отправке данных из файла $file (metric: LV). Код ответа: $response_value2"
                all_success=false
            else
                echo "Данные из файла $file (metric: LV, label: $label2) успешно отправлены."
            fi

        done < <(tail -n +2 "$file")  # Пропускаем первую строку

    # Обработка файлов с "CV" в имени
    elif [[ "$file" == *CV* ]]; then
        # Считываем первую строку для получения имён лейблов (пропускаем первый столбец)
        IFS=$'\t' read -r _ label2 label3 label4 label5 label6 label7 < "$file"

        # Используем awk для обработки строк в файле
        awk -F'\t' -v url="$url" -v label2_name="$label2" -v label3_name="$label3" -v label4_name="$label4" -v label5_name="$label5" -v label6_name="$label6" -v label7_name="$label7" '
        NR > 1 {
            col1 = $1
            col2 = ($2 == "" ? "NULL" : "\"" $2 "\"")
            col3 = ($3 == "" ? "NULL" : "\"" $3 "\"")
            col4 = ($4 == "" ? "NULL" : "\"" $4 "\"")
            col5 = ($5 == "" ? "NULL" : "\"" $5 "\"")
            col6 = ($6 == "" ? "NULL" : "\"" $6 "\"")
            col7 = ($7 == "" ? "NULL" : "\"" $7 "\"")

            data_value = "CV{" label2_name "=" col2 ", " label3_name "=" col3 ", " label4_name "=" col4 ", " label5_name "=" col5 ", " label6_name "=" col6 ", " label7_name "=" col7 "} " col1

            cmd = "curl -s -w \"%{http_code}\" -o /dev/null -X POST -d \047" data_value "\047 " url
            cmd | getline response_value
            close(cmd)

            if (response_value != "200" && response_value != "204") {
                print "Ошибка при отправке данных из файла " FILENAME " (metric: CV). Код ответа: " response_value
            } else {
                print "Данные из файла " FILENAME " (metric: CV) успешно отправлены: " data_value
            }
        }
        ' "$file"
    fi

    # Перемещаем файл в done, если данные успешно отправлены
    if [[ "$all_success" == true ]]; then
        mv "$file" done/
    fi
done
