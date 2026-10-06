FROM public.ecr.aws/lambda/python:3.12

# 依存ライブラリを先に入れる（コードだけ変えたときにキャッシュが効く）
COPY requirements.txt ${LAMBDA_TASK_ROOT}
RUN pip install --no-cache-dir -r requirements.txt

COPY lambda_function.py ${LAMBDA_TASK_ROOT}

CMD [ "lambda_function.lambda_handler" ]
